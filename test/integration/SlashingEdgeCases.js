import {contractId} from "../../utils/helpers"
import batchTranscodeReceiptHashes from "../../utils/batchTranscodeReceipts"
import MerkleTree from "../../utils/merkleTree"
import {createTranscodingOptions} from "../../utils/videoProfile"
import Segment from "../../utils/segment"

const Controller = artifacts.require("Controller")
const BondingManager = artifacts.require("BondingManager")
const JobsManager = artifacts.require("JobsManager")
const AdjustableRoundsManager = artifacts.require("AdjustableRoundsManager")
const LivepeerToken = artifacts.require("LivepeerToken")
const LivepeerTokenFaucet = artifacts.require("LivepeerTokenFaucet")

contract("SlashingEdgeCases", accounts => {
    let controller
    let bondingManager
    let roundsManager
    let jobsManager
    let token

    let transcoder1
    let transcoder2
    let watcher
    let broadcaster

    let roundLength

    before(async () => {
        transcoder1 = accounts[0]
        transcoder2 = accounts[1]
        watcher = accounts[3]
        broadcaster = accounts[3]

        controller = await Controller.deployed()

        const bondingManagerAddr = await controller.getContract(contractId("BondingManager"))
        bondingManager = await BondingManager.at(bondingManagerAddr)

        const roundsManagerAddr = await controller.getContract(contractId("RoundsManager"))
        roundsManager = await AdjustableRoundsManager.at(roundsManagerAddr)

        const jobsManagerAddr = await controller.getContract(contractId("JobsManager"))
        jobsManager = await JobsManager.at(jobsManagerAddr)

        // Set verification rate to 1 out of 1 segments, so every segment is challenged
        await jobsManager.setVerificationRate(1)
        // Set double claim segment slash amount to 20%
        await jobsManager.setDoubleClaimSegmentSlashAmount(200000)
        // Set missed verification slash amount to 20%
        await jobsManager.setMissedVerificationSlashAmount(200000)

        const tokenAddr = await controller.getContract(contractId("LivepeerToken"))
        token = await LivepeerToken.at(tokenAddr)

        const faucetAddr = await controller.getContract(contractId("LivepeerTokenFaucet"))
        const faucet = await LivepeerTokenFaucet.at(faucetAddr)

        await faucet.request({from: transcoder1})
        await faucet.request({from: transcoder2})

        roundLength = await roundsManager.roundLength.call()
        await roundsManager.mineBlocks(roundLength.toNumber() * 1000)
        await roundsManager.initializeRound()

        await token.approve(bondingManager.address, 1000, {from: transcoder1})
        await bondingManager.bond(1000, transcoder1, {from: transcoder1})
        await bondingManager.transcoder(10, 5, 1, {from: transcoder1})

        // Fast forward to new round with locked in active transcoder set
        await roundsManager.mineBlocks(roundLength.toNumber())
        await roundsManager.initializeRound()
    })

    it("transcoder that unbonds should still be slashable for a fault", async () => {
        await jobsManager.deposit({from: broadcaster, value: 1000})

        const endBlock = (await roundsManager.blockNum()).add(100)
        await jobsManager.job("foo", createTranscodingOptions(["foo", "bar"]), 1, endBlock, {from: broadcaster})

        const rand = web3.eth.getBlock(web3.eth.blockNumber).hash
        await roundsManager.mineBlocks(1)
        await roundsManager.setBlockHash(rand)

        // Segment data hashes
        const dataHashes = [
            "0x80084bf2fba02475726feb2cab2d8215eab14bc6bdd8bfb2c8151257032ecd8b",
            "0xb039179a8a4ce2c252aa6f2f25798251c19b75fc1508d9d511a191e0487d64a7",
            "0x263ab762270d3b73d3e2cddf9acc893bb6bd41110347e5d5e4bd1d3c128ea90a",
            "0x4ce8765e720c576f6f5a34ca380b3de5f0912e6e3cc5355542c363891e54594b"
        ]

        // Segments
        const segments = dataHashes.map((dataHash, idx) => new Segment("foo", idx, dataHash, broadcaster))

        // Transcoded data hashes
        const tDataHashes = [
            "0x42538602949f370aa331d2c07a1ee7ff26caac9cc676288f94b82eb2188b8465",
            "0xa0b37b8bfae8e71330bd8e278e4a45ca916d00475dd8b85e9352533454c9fec8",
            "0x9f2898da52dedaca29f05bcac0c8e43e4b9f7cb5707c14cc3f35a567232cec7c",
            "0x5a082c81a7e4d5833ee20bd67d2f4d736f679da33e4bebd3838217cb27bec1d3"
        ]

        // Transcode receipts
        const tReceiptHashes = batchTranscodeReceiptHashes(segments, tDataHashes)

        // Build merkle tree
        const merkleTree = new MerkleTree(tReceiptHashes)

        const tokenStartSupply = await token.totalSupply.call()

        // Transcoder claims segments 0 through 3
        await jobsManager.claimWork(0, [0, 3], merkleTree.getHexRoot(), {from: transcoder1})
        // Transcoder claims segments 0 through 3 again
        await jobsManager.claimWork(0, [0, 3], merkleTree.getHexRoot(), {from: transcoder1})
        // Wait for claims to be mined
        await roundsManager.mineBlocks(2)

        // Transcoder unbonds and tries to avoid being slashed
        await bondingManager.unbond({from: transcoder1})

        // Watcher slashes transcoder for double claiming segments
        // Transcoder claimed segments 0 through 3 twice
        await jobsManager.doubleClaimSegmentSlash(0, 0, 1, 0, {from: watcher})

        // Check that the transcoder is penalized
        const currentRound = await roundsManager.currentRound()
        const doubleClaimSegmentSlashAmount = await jobsManager.doubleClaimSegmentSlashAmount.call()
        const penalty = Math.floor((1000 * doubleClaimSegmentSlashAmount.toNumber()) / 1000000)
        const expTransStakeRemaining = 1000 - penalty
        const expDelegatedStakeRemaining = 0
        const expTotalBondedRemaining = 0
        const tokenEndSupply = await token.totalSupply.call()
        const finderFeeAmount = await jobsManager.finderFee.call()
        const finderFee = Math.floor((penalty * finderFeeAmount) / 1000000)
        const burned = tokenStartSupply.sub(tokenEndSupply).toNumber()
        const trans = await bondingManager.getDelegator(transcoder1)

        assert.isNotOk(await bondingManager.isActiveTranscoder(transcoder1, currentRound), "transcoder should be inactive")
        assert.equal(await bondingManager.transcoderStatus(transcoder1), 0, "transcoder should not be registered")
        assert.equal(trans[0], expTransStakeRemaining, "wrong transcoder stake remaining")
        assert.equal(trans[3], expDelegatedStakeRemaining, "wrong delegated stake remaining")
        assert.equal(burned, penalty - finderFee, "wrong amount burned")

        // Check that the finder was rewarded
        assert.equal(await token.balanceOf(watcher), finderFee, "wrong finder fee")

        // Check that the broadcaster was refunded
        assert.equal((await jobsManager.getJob(0))[8], 0, "job escrow should be 0")
        assert.equal((await jobsManager.broadcasters.call(broadcaster))[0], 1000)

        // Check that the total stake for the round is updated
        // activeTranscoderSet.call(round) only returns the active stake and not the array of transcoder addresses
        // because Solidity does not return nested arrays in structs
        assert.equal(await bondingManager.activeTranscoderSet.call(currentRound), 0, "wrong active stake remaining")

        // Check that the total tokens bonded is updated
        assert.equal(await bondingManager.getTotalBonded(), expTotalBondedRemaining, "wrong total bonded amount")
    })

    it("transcoder that is slashed should still be slashable if it claims work and faults again", async () => {
        await token.approve(bondingManager.address, 1000, {from: transcoder2})
        await bondingManager.bond(1000, transcoder2, {from: transcoder2})
        await bondingManager.transcoder(10, 15, 1, {from: transcoder2})

        // Fast forward to new round with locked in active transcoder set
        await roundsManager.mineBlocks(roundLength.toNumber())
        await roundsManager.initializeRound()

        const endBlock = (await roundsManager.blockNum()).add(100)
        await jobsManager.job("foo", createTranscodingOptions(["foo", "bar"]), 1, endBlock, {from: broadcaster})

        let rand = web3.eth.getBlock(web3.eth.blockNumber).hash
        await roundsManager.mineBlocks(1)
        await roundsManager.setBlockHash(rand)

        // Segment data hashes
        const dataHashes = [
            "0x80084bf2fba02475726feb2cab2d8215eab14bc6bdd8bfb2c8151257032ecd8b",
            "0xb039179a8a4ce2c252aa6f2f25798251c19b75fc1508d9d511a191e0487d64a7",
            "0x263ab762270d3b73d3e2cddf9acc893bb6bd41110347e5d5e4bd1d3c128ea90a",
            "0x4ce8765e720c576f6f5a34ca380b3de5f0912e6e3cc5355542c363891e54594b"
        ]

        // Segments
        const segments = dataHashes.map((dataHash, idx) => new Segment("foo", idx, dataHash, broadcaster))

        // Transcoded data hashes
        const tDataHashes = [
            "0x42538602949f370aa331d2c07a1ee7ff26caac9cc676288f94b82eb2188b8465",
            "0xa0b37b8bfae8e71330bd8e278e4a45ca916d00475dd8b85e9352533454c9fec8",
            "0x9f2898da52dedaca29f05bcac0c8e43e4b9f7cb5707c14cc3f35a567232cec7c",
            "0x5a082c81a7e4d5833ee20bd67d2f4d736f679da33e4bebd3838217cb27bec1d3"
        ]

        // Transcode receipts
        const tReceiptHashes = batchTranscodeReceiptHashes(segments, tDataHashes)

        // Build merkle tree
        const merkleTree = new MerkleTree(tReceiptHashes)

        const tokenStartSupply = await token.totalSupply.call()
        const watcherStartBalance = await token.balanceOf(watcher)

        // Transcoder claims segments 0 through 3
        await jobsManager.claimWork(1, [0, 3], merkleTree.getHexRoot(), {from: transcoder2})
        // Transcoder claims segments 0 through 3 again
        await jobsManager.claimWork(1, [0, 3], merkleTree.getHexRoot(), {from: transcoder2})
        // Wait for claims to be mined
        await roundsManager.mineBlocks(2)

        // Watcher slashes transcoder for double claiming segments
        // Transcoder claimed segments 0 through 3 twice
        await jobsManager.doubleClaimSegmentSlash(1, 0, 1, 0, {from: watcher})

        // Transcoder claims again after it was slashed
        await jobsManager.claimWork(1, [0, 3], merkleTree.getHexRoot(), {from: transcoder2})
        // Wait through the verification period
        const verificationPeriod = await jobsManager.verificationPeriod.call()
        await roundsManager.mineBlocks(verificationPeriod.toNumber() + 1)
        // Make sure the round is initialized
        await roundsManager.initializeRound()

        rand = web3.eth.getBlock(web3.eth.blockNumber).hash
        await roundsManager.setBlockHash(rand)
        // Watcher slashes transcoder for missing verification
        // transcoder should have submitted every segment for verification because the verification rate was 1 out of 1 segments
        await jobsManager.missedVerificationSlash(1, 2, 0, {from: watcher})

        // Check that the transcoder is penalized twice (once for double claiming and once for missing verification)
        const currentRound = await roundsManager.currentRound()
        const doubleClaimSegmentSlashAmount = await jobsManager.doubleClaimSegmentSlashAmount.call()
        const missedVerificationSlashAmount = await jobsManager.missedVerificationSlashAmount.call()
        const penalty1 = Math.floor((1000 * doubleClaimSegmentSlashAmount.toNumber()) / 1000000)
        const transStakeRemaining1 = 1000 - penalty1
        const penalty2 = Math.floor((transStakeRemaining1 * missedVerificationSlashAmount.toNumber()) / 1000000)
        const expTransStakeRemaining = transStakeRemaining1 - penalty2
        const expDelegatedStakeRemaining = expTransStakeRemaining
        const expTotalBondedRemaining = expTransStakeRemaining
        const tokenEndSupply = await token.totalSupply.call()
        const watcherEndBalance = await token.balanceOf(watcher)
        const finderFeeAmount = await jobsManager.finderFee.call()
        const finderFee1 = Math.floor((penalty1 * finderFeeAmount) / 1000000)
        const finderFee2 = Math.floor((penalty2 * finderFeeAmount) / 1000000)
        const burned = tokenStartSupply.sub(tokenEndSupply).toNumber()
        const trans = await bondingManager.getDelegator(transcoder2)

        assert.isNotOk(await bondingManager.isActiveTranscoder(transcoder2, currentRound), "transcoder should be inactive")
        assert.equal(await bondingManager.transcoderStatus(transcoder2), 0, "transcoder should not be registered")
        assert.equal(trans[0], expTransStakeRemaining, "wrong transcoder stake remaining")
        assert.equal(trans[3], expDelegatedStakeRemaining, "wrong delegated stake remaining")
        assert.equal(burned, (penalty1 + penalty2) - (finderFee1 + finderFee2), "wrong amount burned")

        // Check that the finder was rewarded
        assert.equal(watcherEndBalance.sub(watcherStartBalance), finderFee1 + finderFee2, "wrong finder fee")

        // Check that the broadcaster was refunded for both jobs
        assert.equal((await jobsManager.getJob(0))[8], 0, "job escrow should be 0")
        assert.equal((await jobsManager.getJob(1))[8], 0, "job escrow should be 0")
        assert.equal((await jobsManager.broadcasters.call(broadcaster))[0], 1000)

        // Check that the total stake for the round is updated
        // activeTranscoderSet.call(round) only returns the active stake and not the array of transcoder addresses
        // because Solidity does not return nested arrays in structs
        assert.equal(await bondingManager.activeTranscoderSet.call(currentRound), 0, "wrong active stake remaining")

        // Check that the total tokens bonded is updated
        assert.equal(await bondingManager.getTotalBonded(), expTotalBondedRemaining, "wrong total bonded amount")
    })
})
