// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// BR-05 PoC, L2 half: a claim whose LayerZero delivery fails on L2MessageReceiver is permanently lost.
// L1 half is code-proven (see VERDICT.md): DepositPool._claim zeroes pendingRewards and sets lastClaim
// BEFORE Distributor.sendMintMessage fires, and none of DepositPool / Distributor / L1SenderV2 has any
// in-flight record, acknowledgement, resend, or re-credit function.
// This test forks Arbitrum One at a pinned block and shows, against the REAL deployed receiver:
//   1. control: a well-formed delivery mints MOR to the claim receiver;
//   2. once the mint path fails persistently (here: rewardToken points at a token whose mint reverts,
//      the state the owner can create any time via setParams, e.g. a botched token migration; the same
//      permanence holds for minter revocation or a mint cap), lzReceive stores only keccak256(payload)
//      in failedMessages and the claim amount never arrives;
//   3. retryMessage re-executes the IDENTICAL payload and reverts forever; a modified payload is
//      rejected by the hash check, so no corrected re-delivery exists either.
// The gateway address impersonated here is the LayerZero endpoint from the receiver's own live config
// (that is who delivers messages in production); no owner/admin/multisig is impersonated.

interface Vm {
    function createSelectFork(string calldata url, uint256 blockNumber) external returns (uint256);
    function prank(address msgSender) external;
    function load(address target, bytes32 slot) external returns (bytes32);
    function store(address target, bytes32 slot, bytes32 value) external;
    function expectRevert() external;
}

interface IL2MessageReceiver {
    function rewardToken() external view returns (address);
    function config() external view returns (address gateway, address sender, uint16 senderChainId);
    function lzReceive(uint16 senderChainId_, bytes memory senderAndReceiverAddresses_, uint64 nonce_, bytes memory payload_) external;
    function retryMessage(uint16 senderChainId_, bytes memory senderAndReceiverAddresses_, uint64 nonce_, bytes memory payload_) external;
    function failedMessages(uint16, bytes memory, uint64) external view returns (bytes32);
}

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
}

contract BadToken {
    function mint(address, uint256) external pure {
        revert("BadToken: mint disabled");
    }
}

contract BR05Test {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    address constant RECEIVER = 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427; // L2MessageReceiver proxy, Arbitrum
    address constant MOR_ARB = 0x092bAaDB7DEf4C3981454dD9c0A0D7FF07bCFc86;
    uint256 constant FORK_BLOCK = 525256398;
    uint64 constant NONCE_OK = 9999001;
    uint64 constant NONCE_FAIL = 9999002;

    address user = address(0x2001);
    address anyone = address(0x2002);

    function _assertEq(uint256 a, uint256 b, string memory what) internal pure {
        if (a != b) revert(string(abi.encodePacked("ASSERT FAIL ", what)));
    }

    function _setRewardToken(address badToken) internal {
        IL2MessageReceiver r = IL2MessageReceiver(RECEIVER);
        for (uint256 slot = 0; slot < 420; slot++) {
            bytes32 key = bytes32(slot);
            bytes32 old = vm.load(RECEIVER, key);
            vm.store(RECEIVER, key, bytes32(uint256(uint160(badToken))));
            if (r.rewardToken() == badToken) return;
            vm.store(RECEIVER, key, old);
        }
        revert("rewardToken slot not found");
    }

    function test_FailedClaimIsPermanentlyLost() public {
        vm.createSelectFork("https://arb1.arbitrum.io/rpc", FORK_BLOCK);
        IL2MessageReceiver receiver = IL2MessageReceiver(RECEIVER);

        (address gateway, address sender, uint16 senderChainId) = receiver.config();
        require(gateway != address(0) && sender != address(0), "config empty");
        bytes memory path = abi.encodePacked(sender, RECEIVER);
        uint256 amount = 100 ether;
        bytes memory payload = abi.encode(user, amount);

        // --- 1. control: normal delivery mints ---
        uint256 bal0 = IERC20(MOR_ARB).balanceOf(user);
        vm.prank(gateway);
        receiver.lzReceive(senderChainId, path, NONCE_OK, payload);
        _assertEq(IERC20(MOR_ARB).balanceOf(user), bal0 + amount, "control mint failed");

        // --- 2. persistent mint failure: delivery is swallowed, only a hash is stored ---
        BadToken bad = new BadToken();
        _setRewardToken(address(bad));

        vm.prank(gateway);
        receiver.lzReceive(senderChainId, path, NONCE_FAIL, payload); // does not revert (nonblocking pattern)
        _assertEq(IERC20(MOR_ARB).balanceOf(user), bal0 + amount, "failed claim minted anyway");
        bytes32 stored = receiver.failedMessages(senderChainId, path, NONCE_FAIL);
        require(stored == keccak256(payload), "failed message hash not stored");

        // --- 3. retry re-runs the identical payload and reverts, forever ---
        vm.prank(anyone);
        vm.expectRevert();
        receiver.retryMessage(senderChainId, path, NONCE_FAIL, payload);

        vm.prank(anyone);
        vm.expectRevert();
        receiver.retryMessage(senderChainId, path, NONCE_FAIL, payload);

        // a corrected payload (e.g. different recipient) is rejected by the hash check
        bytes memory fixedPayload = abi.encode(anyone, amount);
        vm.prank(anyone);
        vm.expectRevert();
        receiver.retryMessage(senderChainId, path, NONCE_FAIL, fixedPayload);

        // state after all retries: hash still stored, claim amount still missing
        require(receiver.failedMessages(senderChainId, path, NONCE_FAIL) == keccak256(payload), "failed hash cleared");
        _assertEq(IERC20(MOR_ARB).balanceOf(user), bal0 + amount, "claim recovered somehow");
    }
}
