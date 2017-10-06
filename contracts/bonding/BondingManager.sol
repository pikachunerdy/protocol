pragma solidity ^0.4.13;

import "../ManagerProxyTarget.sol";
import "./IBondingManager.sol";
import "./libraries/TranscoderPools.sol";
import "../token/ILivepeerToken.sol";
import "../token/IMinter.sol";
import "../rounds/IRoundsManager.sol";
import "../jobs/IJobsManager.sol";

import "zeppelin-solidity/contracts/math/SafeMath.sol";


contract BondingManager is ManagerProxyTarget, IBondingManager {
    using SafeMath for uint256;
    using TranscoderPools for TranscoderPools.TranscoderPools;

    // Time between unbonding and possible withdrawl in rounds
    uint64 public unbondingPeriod;

    // Represents a transcoder's current state
    struct Transcoder {
        uint256 delegatorWithdrawRound;                      // The round at which delegators to this transcoder can withdraw if this transcoder resigns
        uint256 lastRewardRound;                             // Last round that the transcoder called reward
        uint8 blockRewardCut;                                // % of block reward cut paid to transcoder by a delegator
        uint8 feeShare;                                      // % of fees paid to delegators by transcoder
        uint256 pricePerSegment;                             // Price per segment (denominated in LPT units) for a stream
        uint8 pendingBlockRewardCut;                         // Pending block reward cut for next round if the transcoder is active
        uint8 pendingFeeShare;                               // Pending fee share for next round if the transcoder is active
        uint256 pendingPricePerSegment;                      // Pending price per segment for next round if the transcoder is active
        mapping (uint256 => TokenPools) tokenPoolsPerRound;  // Mapping of round => token pools for the round
    }

    // The various states a transcoder can be in
    enum TranscoderStatus { NotRegistered, Registered, Resigned }

    // Represents rewards and fees to be distributed to delegators
    struct TokenPools {
        uint256 rewardPool;      // Reward tokens in the pool
        uint256 feePool;         // Fee tokens in the pool. stakeRemaining / totalStake = % of claimable fees in the pool
        uint256 totalStake;      // Transcoder's total stake during the pool's round
        uint256 stakeRemaining;  // Stake that has not been used to claim fees in the pool
    }

    // Represents a delegator's current state
    struct Delegator {
        uint256 bondedAmount;              // The amount of bonded tokens
        address delegateAddress;           // The address delegated to
        uint256 delegatedAmount;           // The amount of tokens delegated to the delegator
        uint256 startRound;                // The round the delegator transitions to bonded phase and is delegated to someone
        uint256 withdrawRound;             // The round at which a delegator can withdraw
        uint256 lastStakeUpdateRound;      // The last round the delegator updated its stake
    }

    // The various states a delegator can be in
    enum DelegatorStatus { Pending, Bonded, Unbonding, Unbonded }

    // Keep track of the known transcoders and delegators
    mapping (address => Delegator) delegators;
    mapping (address => Transcoder) transcoders;

    // Candidate and reserve transcoder pools
    TranscoderPools.TranscoderPools transcoderPools;

    // Current active transcoders for current round
    Node.Node[] activeTranscoders;
    // Mapping to track which addresses are in the current active transcoder set
    mapping (address => bool) public isActiveTranscoder;
    // Mapping to track the index position of an address in the current active transcoder set
    mapping (address => uint256) public activeTranscoderPositions;
    // Total stake of all active transcoders
    uint256 public totalActiveTranscoderStake;

    // Only the RoundsManager can call
    modifier onlyRoundsManager() {
        require(IRoundsManager(msg.sender) == roundsManager());
        _;
    }

    // Only the JobsManager can call
    modifier onlyJobsManager() {
        require(IJobsManager(msg.sender) == jobsManager());
        _;
    }

    // Check if current round is initialized
    modifier currentRoundInitialized() {
        require(roundsManager().currentRoundInitialized());
        _;
    }

    // Automatically update a delegator's stake from lastStakeUpdateRound through the current round
    modifier autoUpdateDelegatorStake() {
        updateDelegatorStakeWithRewardsAndFees(msg.sender, roundsManager().currentRound());
        _;
    }

    function BondingManager(address _controller) Manager(_controller) {}

    function initialize(uint64 _unbondingPeriod, uint256 _numActiveTranscoders) external beforeInitialization returns (bool) {
        finishInitialization();
        // Set unbonding period
        unbondingPeriod = _unbondingPeriod;
        // Set up transcoder pools
        transcoderPools.init(_numActiveTranscoders, _numActiveTranscoders);
    }

    /*
     * @dev The sender is declaring themselves as a candidate for active transcoding.
     * @param _blockRewardCut % of block reward paid to transcoder by a delegator
     * @param _feeShare % of fees paid to delegators by a transcoder
     * @param _pricePerSegment Price per segment (denominated in LPT units) for a stream
     */
    function transcoder(uint8 _blockRewardCut, uint8 _feeShare, uint256 _pricePerSegment)
        external
        afterInitialization
        whenSystemNotPaused
        currentRoundInitialized
        returns (bool)
    {
        // Block reward cut must a valid percentage
        require(_blockRewardCut <= 100);
        // Fee share must be a valid percentage
        require(_feeShare <= 100);
        // Sender must not be a resigned transcoder
        require(transcoderStatus(msg.sender) != TranscoderStatus.Resigned);

        Transcoder storage t = transcoders[msg.sender];
        t.pendingBlockRewardCut = _blockRewardCut;
        t.pendingFeeShare = _feeShare;
        t.pendingPricePerSegment = _pricePerSegment;

        if (transcoderStatus(msg.sender) == TranscoderStatus.NotRegistered) {
            t.delegatorWithdrawRound = 0;

            transcoderPools.addTranscoder(msg.sender, delegators[msg.sender].delegatedAmount);
        }

        return true;
    }

    /*
     * @dev Remove the sender as a transcoder
     */
    function resignAsTranscoder()
        external
        afterInitialization
        whenSystemNotPaused
        currentRoundInitialized
        returns (bool)
    {
        // Sender must be registered transcoder
        require(transcoderStatus(msg.sender) == TranscoderStatus.Registered);
        // Remove transcoder from pools
        transcoderPools.removeTranscoder(msg.sender);
        // Set delegator withdraw round
        transcoders[msg.sender].delegatorWithdrawRound = roundsManager().currentRound().add(unbondingPeriod);

        return true;
    }

    /**
     * @dev Delegate stake towards a specific address.
     * @param _amount The amount of LPT to stake.
     * @param _to The address of the transcoder to stake towards.
     */
    function bond(
        uint256 _amount,
        address _to
    )
        external
        afterInitialization
        whenSystemNotPaused
        currentRoundInitialized
        autoUpdateDelegatorStake
        returns (bool)
    {
        Delegator storage del = delegators[msg.sender];

        if (delegatorStatus(msg.sender) == DelegatorStatus.Unbonded) {
            // New delegate
            // Set start round
            del.startRound = roundsManager().currentRound().add(1);
        }

        // Amount to delegate
        uint256 delegationAmount = _amount;

        if (del.delegateAddress != address(0) && _to != del.delegateAddress) {
            // Changing delegate
            // Set start round
            del.startRound = roundsManager().currentRound().add(1);
            // Update amount to delegate with previous delegation amount
            delegationAmount = delegationAmount.add(del.bondedAmount);
            // Decrease old delegate's delegated amount
            delegators[del.delegateAddress].delegatedAmount = delegators[del.delegateAddress].delegatedAmount.sub(del.bondedAmount);

            if (transcoderStatus(del.delegateAddress) == TranscoderStatus.Registered) {
                // Previously delegated to a transcoder
                // Decrease old transcoder's total stake
                transcoderPools.decreaseTranscoderStake(del.delegateAddress, del.bondedAmount);
            }
        }

        del.delegateAddress = _to;
        del.bondedAmount = del.bondedAmount.add(_amount);

        // Update current delegate's delegated amount with delegation amount
        delegators[_to].delegatedAmount = delegators[_to].delegatedAmount.add(delegationAmount);

        if (transcoderStatus(_to) == TranscoderStatus.Registered) {
            // Delegated to a transcoder
            // Increase transcoder's total stake
            transcoderPools.increaseTranscoderStake(_to, delegationAmount);
        }

        if (_amount > 0) {
            // Only transfer tokens if _amount is greater than 0
            // Transfer the token to the Minter
            livepeerToken().transferFrom(msg.sender, minter(), _amount);
        }

        return true;
    }

    /*
     * @dev Unbond delegator's current stake. Delegator enters unbonding state
     * @param _amount Amount of tokens to unbond
     */
    function unbond()
        external
        afterInitialization
        whenSystemNotPaused
        currentRoundInitialized
        autoUpdateDelegatorStake
        returns (bool)
    {
        // Sender must be in bonded state
        require(delegatorStatus(msg.sender) == DelegatorStatus.Bonded);

        Delegator storage del = delegators[msg.sender];

        // Transition to unbonding phase
        del.withdrawRound = roundsManager().currentRound().add(unbondingPeriod);
        // Decrease delegate's delegated amount
        delegators[del.delegateAddress].delegatedAmount = delegators[del.delegateAddress].delegatedAmount.sub(del.bondedAmount);

        if (transcoderStatus(del.delegateAddress) == TranscoderStatus.Registered) {
            // Previously delegated to a transcoder
            // Decrease old transcoder's total stake
            transcoderPools.decreaseTranscoderStake(del.delegateAddress, del.bondedAmount);
        }

        // Delegator no longer bonded to anyone
        del.delegateAddress = address(0);

        return true;
    }

    /**
     * @dev Withdraws withdrawable funds back to the caller after unbonding period.
     */
    function withdraw() external afterInitialization whenSystemNotPaused currentRoundInitialized returns (bool) {
        // Delegator must be unbonded
        require(delegatorStatus(msg.sender) == DelegatorStatus.Unbonded);

        // Ask Minter to transfer tokens to sender
        minter().transferTokens(msg.sender, delegators[msg.sender].bondedAmount);

        delete delegators[msg.sender];

        return true;
    }

    /*
     * @dev Set active transcoder set for the current round
     */
    function setActiveTranscoders() external afterInitialization whenSystemNotPaused onlyRoundsManager returns (bool) {
        if (activeTranscoders.length != transcoderPools.candidateTranscoders.nodes.length) {
            // Set length of array if it has not already been set
            activeTranscoders.length = transcoderPools.candidateTranscoders.nodes.length;
        }

        uint256 stake = 0;

        for (uint256 i = 0; i < transcoderPools.candidateTranscoders.nodes.length; i++) {
            if (activeTranscoders[i].initialized) {
                // Set address of old node to not be present in active transcoder set
                isActiveTranscoder[activeTranscoders[i].id] = false;
            }

            // Copy node
            activeTranscoders[i] = transcoderPools.candidateTranscoders.nodes[i];

            address activeTranscoder = activeTranscoders[i].id;

            // Set address of node to be present in active transcoder set
            isActiveTranscoder[activeTranscoder] = true;
            // Set index position of node in active transcoder set
            activeTranscoderPositions[activeTranscoder] = i;
            // Set pending rates as current rates
            transcoders[activeTranscoder].blockRewardCut = transcoders[activeTranscoder].pendingBlockRewardCut;
            transcoders[activeTranscoder].feeShare = transcoders[activeTranscoder].pendingFeeShare;
            transcoders[activeTranscoder].pricePerSegment = transcoders[activeTranscoder].pendingPricePerSegment;

            stake = stake.add(transcoderTotalStake(activeTranscoder));
        }

        // Update total stake of all active transcoders
        totalActiveTranscoderStake = stake;

        return true;
    }

    /*
     * @dev Distribute the token rewards to transcoder and delegates.
     * Active transcoders call this once per cycle when it is their turn.
     */
    function reward() external afterInitialization whenSystemNotPaused currentRoundInitialized returns (bool) {
        // Sender must be an active transcoder
        require(isActiveTranscoder[msg.sender]);

        uint256 currentRound = roundsManager().currentRound();

        // Transcoder must not have called reward for this round already
        require(transcoders[msg.sender].lastRewardRound != currentRound);
        // Set last round that transcoder called reward
        transcoders[msg.sender].lastRewardRound = currentRound;

        // Create reward
        uint256 rewardTokens = minter().createReward(activeTranscoders[activeTranscoderPositions[msg.sender]].key, totalActiveTranscoderStake);

        updateTranscoderWithRewards(msg.sender, rewardTokens, currentRound);

        return true;
    }

    /*
     * @dev Update transcoder's fee pool
     * @param _transcoder Transcoder address
     * @param _fees Fees from verified job claims
     */
    function updateTranscoderFeePool(
        address _transcoder,
        uint256 _fees,
        uint256 _round
    )
        external
        afterInitialization
        whenSystemNotPaused
        onlyJobsManager
        returns (bool)
    {
        // Transcoder must be registered
        require(transcoderStatus(_transcoder) == TranscoderStatus.Registered);

        // Only add claimable fees to the fee pool for the round
        // Add unclaimable fees to the redistribution pool
        TokenPools storage tokenPools = transcoders[_transcoder].tokenPoolsPerRound[_round];
        uint256 claimableFees = _fees.mul(tokenPools.stakeRemaining).div(tokenPools.totalStake);
        if (claimableFees < _fees) {
            minter().addToRedistributionPool(_fees.sub(claimableFees));
        }

        updateTranscoderWithFees(_transcoder, claimableFees, _round);

        return true;
    }

    /*
     * @dev Slash a transcoder. Slashing can be invoked by the protocol or a finder.
     * @param _transcoder Transcoder address
     * @param _finder Finder that proved a transcoder violated a slashing condition. Null address if there is no finder
     * @param _slashAmount Percentage of transcoder bond to be slashed
     * @param _finderFee Percentage of penalty awarded to finder. Zero if there is no finder
     */
    function slashTranscoder(
        address _transcoder,
        address _finder,
        uint64 _slashAmount,
        uint64 _finderFee
    )
        external
        afterInitialization
        whenSystemNotPaused
        onlyJobsManager
        returns (bool)
    {
        // Transcoder must be valid
        require(transcoderStatus(_transcoder) == TranscoderStatus.Registered);

        uint256 penalty = delegators[_transcoder].bondedAmount.mul(_slashAmount).div(100);

        decreaseTranscoderStake(_transcoder, penalty);

        // Set withdraw round for delegators
        transcoders[msg.sender].delegatorWithdrawRound = roundsManager().currentRound().add(unbondingPeriod);

        // Remove transcoder from pools
        transcoderPools.removeTranscoder(_transcoder);

        if (_finder != address(0)) {
            // Award finder fee
            minter().transferTokens(_finder, penalty.mul(_finderFee).div(100));
        }

        return true;
    }

    /*
     * @dev Pseudorandomly elect a currently active transcoder that charges a price per segment less than or equal to the max price per segment for a job
     * Returns address of elected active transcoder and its price per segment
     * @param _maxPricePerSegment Max price (in LPT base units) per segment of a stream
     */
    function electActiveTranscoder(uint256 _maxPricePerSegment) external returns (address) {
        // Create array to store available transcoders charging an acceptable price per segment
        Node.Node[] memory availableTranscoders = new Node.Node[](activeTranscoders.length);
        // Keep track of the actual number of available transcoders
        uint256 numAvailableTranscoders = 0;
        // Keep track of total stake of available transcoders
        uint256 totalAvailableTranscoderStake = 0;

        for (uint256 i = 0; i < activeTranscoders.length; i++) {
            // If a transcoders charges an acceptable price per segment add it to the array of available transcoders
            if (transcoders[activeTranscoders[i].id].pricePerSegment <= _maxPricePerSegment) {
                availableTranscoders[numAvailableTranscoders] = activeTranscoders[i];
                numAvailableTranscoders++;
                totalAvailableTranscoderStake = totalAvailableTranscoderStake.add(activeTranscoders[i].key);
            }
        }

        if (numAvailableTranscoders == 0) {
            // There is no currently available transcoder that charges a price per segment less than or equal to the max price per segment for a job
            return address(0);
        } else {
            address electedTranscoder = availableTranscoders[numAvailableTranscoders - 1].id;
            uint256 electedStake = availableTranscoders[numAvailableTranscoders - 1].key;

            // Pseudorandomly pick an available transcoder weighted by its stake relative to the total stake of all available transcoders
            uint256 r = uint256(block.blockhash(block.number - 1)) % totalAvailableTranscoderStake;
            uint256 s = 0;

            for (uint256 j = 0; j < numAvailableTranscoders; j++) {
                s = s.add(availableTranscoders[j].key);

                if (s > r) {
                    electedTranscoder = availableTranscoders[j].id;
                    electedStake = availableTranscoders[j].key;
                    break;
                }
            }

            // Set total stake for fee pool for current round
            uint256 currentRound = roundsManager().currentRound();
            TokenPools storage tokenPools = transcoders[electedTranscoder].tokenPoolsPerRound[currentRound];
            if (tokenPools.totalStake == 0) {
                tokenPools.totalStake = electedStake;
                tokenPools.stakeRemaining = electedStake;
            }

            return electedTranscoder;
        }
    }

    /*
     * @dev Update a delegator stake from its last stake update round through the end round
     * @param _endRound The last round for which to update a delegator's stake using the round's fee/reward pools
     */
    function updateDelegatorStake(uint256 _endRound) external returns (bool) {
        require(delegators[msg.sender].lastStakeUpdateRound < _endRound);

        return updateDelegatorStakeWithRewardsAndFees(msg.sender, _endRound);
    }

    /*
     * @dev Returns bonded stake for a delegator. Accounts for token distribution since last state transition
     * @param _delegator Address of delegator
     */
    function delegatorStake(address _delegator) public constant returns (uint256) {
        Delegator storage del = delegators[_delegator];

        // Add rewards and fees from the rounds during which the delegator was bonded to a transcoder
        if (delegatorStatus(_delegator) == DelegatorStatus.Bonded && transcoderStatus(del.delegateAddress) == TranscoderStatus.Registered) {
            uint256 currentRound = roundsManager().currentRound();
            uint256 totalRewards = 0;
            uint256 totalFees = 0;

            for (uint256 i = del.lastStakeUpdateRound + 1; i <= currentRound; i++) {
                // Calculate rewards based on delegator's updated stake at each round
                totalRewards = totalRewards.add(rewardPoolShare(del.delegateAddress, del.bondedAmount.add(totalRewards), i));
                // Calculate fees based on delegator's stake at lastStakeUpdateRound
                totalFees = totalFees.add(feePoolShare(del.delegateAddress, del.bondedAmount, i));
            }

            return del.bondedAmount.add(totalRewards).add(totalFees);
        } else {
            return del.bondedAmount;
        }
    }

    /*
     * @dev Returns total bonded stake for an active transcoder
     * @param _transcoder Address of a transcoder
     */
    function activeTranscoderTotalStake(address _transcoder) public constant returns (uint256) {
        // Must be active transcoder
        require(isActiveTranscoder[_transcoder]);

        return activeTranscoders[activeTranscoderPositions[_transcoder]].key;
    }

    /*
     * @dev Returns total bonded stake for a transcoder
     * @param _transcoder Address of transcoder
     */
    function transcoderTotalStake(address _transcoder) public constant returns (uint256) {
        return transcoderPools.transcoderStake(_transcoder);
    }

    /*
     * @dev Computes transcoder status
     * @param _transcoder Address of transcoder
     */
    function transcoderStatus(address _transcoder) public constant returns (TranscoderStatus) {
        Transcoder storage t = transcoders[_transcoder];

        if (t.delegatorWithdrawRound > 0) {
            if (roundsManager().currentRound() >= t.delegatorWithdrawRound) {
                return TranscoderStatus.NotRegistered;
            } else {
                return TranscoderStatus.Resigned;
            }
        } else if (transcoderPools.isInPools(_transcoder)) {
            return TranscoderStatus.Registered;
        } else {
            return TranscoderStatus.NotRegistered;
        }
    }

    /*
     * @dev Computes delegator status
     * @param _delegator Address of delegator
     */
    function delegatorStatus(address _delegator) public constant returns (DelegatorStatus) {
        Delegator storage del = delegators[_delegator];

        if (del.withdrawRound > 0) {
            // Delegator called unbond
            if (roundsManager().currentRound() >= del.withdrawRound) {
                return DelegatorStatus.Unbonded;
            } else {
                return DelegatorStatus.Unbonding;
            }
        } else if (transcoderStatus(del.delegateAddress) == TranscoderStatus.NotRegistered && transcoders[del.delegateAddress].delegatorWithdrawRound > 0) {
            // Transcoder resigned
            if (roundsManager().currentRound() >= transcoders[del.delegateAddress].delegatorWithdrawRound) {
                return DelegatorStatus.Unbonded;
            } else {
                return DelegatorStatus.Unbonding;
            }
        } else if (del.startRound > roundsManager().currentRound()) {
            // Delegator round start is in the future
            return DelegatorStatus.Pending;
        } else if (del.startRound > 0 && del.startRound <= roundsManager().currentRound()) {
            // Delegator round start is now or in the past
            return DelegatorStatus.Bonded;
        } else {
            // Default to unbonded
            return DelegatorStatus.Unbonded;
        }
    }

    // Transcoder getters

    function getTranscoderDelegatorWithdrawRound(address _transcoder) public constant returns (uint256) {
        return transcoders[_transcoder].delegatorWithdrawRound;
    }

    function getTranscoderLastRewardRound(address _transcoder) public constant returns (uint256) {
        return transcoders[_transcoder].lastRewardRound;
    }

    function getTranscoderBlockRewardCut(address _transcoder) public constant returns (uint8) {
        return transcoders[_transcoder].blockRewardCut;
    }

    function getTranscoderFeeShare(address _transcoder) public constant returns (uint8) {
        return transcoders[_transcoder].feeShare;
    }

    function getTranscoderPricePerSegment(address _transcoder) public constant returns (uint256) {
        return transcoders[_transcoder].pricePerSegment;
    }

    function getTranscoderPendingBlockRewardCut(address _transcoder) public constant returns (uint8) {
        return transcoders[_transcoder].pendingBlockRewardCut;
    }

    function getTranscoderPendingFeeShare(address _transcoder) public constant returns (uint8) {
        return transcoders[_transcoder].pendingFeeShare;
    }

    function getTranscoderPendingPricePerSegment(address _transcoder) public constant returns (uint256) {
        return transcoders[_transcoder].pendingPricePerSegment;
    }

    // Delegator getters

    function getDelegatorBondedAmount(address _delegator) public constant returns (uint256) {
        return delegators[_delegator].bondedAmount;
    }

    function getDelegatorDelegateAddress(address _delegator) public constant returns (address) {
        return delegators[_delegator].delegateAddress;
    }

    function getDelegatorDelegatedAmount(address _delegator) public constant returns (uint256) {
        return delegators[_delegator].delegatedAmount;
    }

    function getDelegatorStartRound(address _delegator) public constant returns (uint256) {
        return delegators[_delegator].startRound;
    }

    function getDelegatorWithdrawRound(address _delegator) public constant returns (uint256) {
        return delegators[_delegator].withdrawRound;
    }

    function getDelegatorLastStakeUpdateRound(address _delegator) public constant returns (uint256) {
        return delegators[_delegator].lastStakeUpdateRound;
    }

    /*
     * @dev Return current size of candidate transcoder pool
     */
    function getCandidatePoolSize() public constant returns (uint256) {
        return transcoderPools.getCandidatePoolSize();
    }

    /*
     * @dev Return current size of reserve transcoder pool
     */
    function getReservePoolSize() public constant returns (uint256) {
        return transcoderPools.getReservePoolSize();
    }

    /*
     * @dev Return candidate transcoder at position in candidate pool
     * @param _position Position in candidate pool
     */
    function getCandidateTranscoderAtPosition(uint256 _position) public constant returns (address) {
        return transcoderPools.getCandidateTranscoderAtPosition(_position);
    }

    /*
     * @dev Return reserve transcoder at postion in reserve pool
     * @param _position Position in reserve pool
     */
    function getReserveTranscoderAtPosition(uint256 _position) public constant returns (address) {
        return transcoderPools.getReserveTranscoderAtPosition(_position);
    }

    /*
     * @dev Increase a transcoder's stake as a delegator and its total stake in the transcoder pools
     * @param _transcoder Address of transcoder
     * @param _totalAmount Total amount to increase transcoder's total stake
     * @param _transcoderShare Transcoder's share of the total amount
     * @param _round Round that transcoder's stake is increased
     */
    function increaseTranscoderStake(address _transcoder, uint256 _totalAmount, uint256 _transcoderShare, uint256 _round) internal returns (bool) {
        delegators[_transcoder].bondedAmount = delegators[_transcoder].bondedAmount.add(_transcoderShare);
        delegators[_transcoder].delegatedAmount = delegators[_transcoder].delegatedAmount.add(_totalAmount);

        if (delegatorStatus(_transcoder) == DelegatorStatus.Unbonded) {
            // Set delegator fields if transcoder is not a bonded delegator
            delegators[_transcoder].delegateAddress = _transcoder;
            delegators[_transcoder].startRound = _round;
            delegators[_transcoder].withdrawRound = 0;
            delegators[_transcoder].lastStakeUpdateRound = _round;
        }

        transcoderPools.increaseTranscoderStake(_transcoder, _totalAmount);

        return true;
    }

    /*
     * @dev Decrease a transcoder's stake as a delegator and its total stake in the transcoder pools
     * @param _transcoder Address of transcoder
     * @param _totalAmount Total amount to decrease transcoder's total stake
     */
    function decreaseTranscoderStake(address _transcoder, uint256 _totalAmount) internal returns (bool) {
        Delegator storage del = delegators[_transcoder];

        if (_totalAmount > del.bondedAmount) {
            // Decrease transcoder's total stake by transcoder's stake
            transcoderPools.decreaseTranscoderStake(_transcoder, del.bondedAmount);
            // Set transcoder's bond to 0 since
            // the penalty is greater than its stake
            del.bondedAmount = 0;
        } else {
            // Decrease transcoder's total stake by the penalty
            transcoderPools.decreaseTranscoderStake(_transcoder, _totalAmount);
            // Decrease transcoder's stake
            del.bondedAmount = del.bondedAmount.sub(_totalAmount);
        }

        return true;
    }

    /*
     * @dev Update a transcoder with rewards
     * @param _transcoder Address of transcoder
     * @param _rewards Amount of rewards
     * @param _round Round that transcoder is updated
     */
    function updateTranscoderWithRewards(address _transcoder, uint256 _rewards, uint256 _round) internal returns (bool) {
        uint256 transcoderRewardShare = _rewards.mul(transcoders[_transcoder].blockRewardCut).div(100);

        // Update transcoder's reward pool for the round
        TokenPools storage tokenPools = transcoders[_transcoder].tokenPoolsPerRound[_round];
        tokenPools.rewardPool = tokenPools.rewardPool.add(_rewards.sub(transcoderRewardShare));
        if (tokenPools.totalStake == 0) {
            tokenPools.totalStake = activeTranscoderTotalStake(_transcoder);
        }

        increaseTranscoderStake(_transcoder, _rewards, transcoderRewardShare, _round);

        return true;
    }

    /*
     * @dev Update a transcoder with fees
     * @param _transcoder Address of transcoder
     * @param _fees Amount of fees
     * @param _round Round that transcoder is updated
     * @param _claimBlock Block of the claim that fees are associated with
     * @param _transcoderTotalStake Transcoder's total stake at the claim block
     */
    function updateTranscoderWithFees(address _transcoder, uint256 _fees, uint256 _round) internal returns (bool) {
        uint256 delegatorsFeeShare = _fees.mul(transcoders[_transcoder].feeShare).div(100);

        // Update transcoder's fee pool for the round
        TokenPools storage tokenPools = transcoders[_transcoder].tokenPoolsPerRound[_round];
        tokenPools.feePool = tokenPools.feePool.add(delegatorsFeeShare);

        increaseTranscoderStake(_transcoder, _fees, _fees.sub(delegatorsFeeShare), _round);

        return true;
    }

    /*
     * @dev Update a delegator with rewards and fees from its last stake update round through a given round
     * @param _delegator Delegator address
     * @param _endRound The last round for which to update a delegator's stake with the round's fee/reward pools
     */
    function updateDelegatorStakeWithRewardsAndFees(address _delegator, uint256 _endRound) internal returns (bool) {
        Delegator storage del = delegators[_delegator];

        if (delegatorStatus(_delegator) == DelegatorStatus.Bonded && transcoderStatus(del.delegateAddress) == TranscoderStatus.Registered) {
            uint256 totalRewards = 0;
            uint256 totalFees = 0;

            for (uint256 i = del.lastStakeUpdateRound + 1; i <= _endRound; i++) {
                totalRewards = totalRewards.add(rewardPoolShare(del.delegateAddress, del.bondedAmount.add(totalRewards), i));
                totalFees = totalFees.add(claimFeePoolShare(del.delegateAddress, del.bondedAmount, i));
            }

            del.bondedAmount = del.bondedAmount.add(totalRewards).add(totalFees);
        }

        del.lastStakeUpdateRound = _endRound;

        return true;
    }

    function claimFeePoolShare(address _transcoder, uint256 _stake, uint256 _round) internal returns (uint256) {
        TokenPools storage tokenPools = transcoders[_transcoder].tokenPoolsPerRound[_round];

        if (tokenPools.feePool == 0) {
            return 0;
        } else {
            uint256 claimedFees = tokenPools.feePool.mul(_stake).div(tokenPools.stakeRemaining);
            tokenPools.feePool = tokenPools.feePool.sub(claimedFees);
            tokenPools.stakeRemaining = tokenPools.stakeRemaining.sub(_stake);

            return claimedFees;
        }
    }

    /*
     * @dev Computes delegator's share of reward pool for a round
     */
    function rewardPoolShare(address _transcoder, uint256 _stake, uint256 _round) internal constant returns (uint256) {
        TokenPools storage tokenPools = transcoders[_transcoder].tokenPoolsPerRound[_round];

        if (tokenPools.rewardPool == 0) {
            return 0;
        } else {
            return tokenPools.rewardPool.mul(_stake).div(tokenPools.totalStake);
        }
    }

    /*
     * @dev Computes delegator's share of fee pool for a round
     */
    function feePoolShare(address _transcoder, uint256 _stake, uint256 _round) internal constant returns (uint256) {
        TokenPools storage tokenPools = transcoders[_transcoder].tokenPoolsPerRound[_round];

        if (tokenPools.feePool == 0) {
            return 0;
        } else {
            return tokenPools.feePool.mul(_stake).div(tokenPools.stakeRemaining);
        }
    }

    /*
     * @dev Return LivepeerToken
     */
    function livepeerToken() internal constant returns (ILivepeerToken) {
        return ILivepeerToken(controller.getContract(keccak256("LivepeerToken")));
    }

    /*
     * @dev Return Minter
     */
    function minter() internal constant returns (IMinter) {
        return IMinter(controller.getContract(keccak256("Minter")));
    }

    /*
     * @dev Return RoundsManager
     */
    function roundsManager() internal constant returns (IRoundsManager) {
        return IRoundsManager(controller.getContract(keccak256("RoundsManager")));
    }

    /*
     * @dev Return JobsManager
     */
    function jobsManager() internal constant returns (IJobsManager) {
        return IJobsManager(controller.getContract(keccak256("JobsManager")));
    }
}
