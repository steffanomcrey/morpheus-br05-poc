TARGET
Reward claim path across the L1 to L2 bridge (all Appendix A): DepositPool 0xdB10dAEF167eA2233Ba6811457dD24D676FbD670 (shared implementation of all five Ethereum DepositPools) function _claim; Distributor 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A function sendMintMessage; L1SenderV2 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84 function sendMintMessage; L2MessageReceiver 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427 on Arbitrum, functions lzReceive / retryMessage / _nonblockingLzReceive. All sources are the Sourcify-verified deployed sources.

INVARIANT
A user's accrued MOR rewards must either be minted to the claim receiver on L2 or remain claimable on L1. Consuming the L1 claim state for a delivery that never mints, with no record and no recovery path, breaks this invariant.

IMPACT
DepositPool._claim writes userData.pendingRewards = 0 and userData.lastClaim = block.timestamp BEFORE calling Distributor.sendMintMessage, which forwards to L1SenderV2.sendMintMessage and fires a LayerZero message. None of the three L1 contracts keeps any in-flight record, and none has a retry, resend, acknowledgement, or re-credit function (full function inventory verified). On L2, a failed mint is caught by the nonblocking pattern and only keccak256(payload) is stored in failedMessages; retryMessage re-executes the identical payload, whose sole effect is IMOR(rewardToken).mint(user, amount). If the mint fails persistently (rewardToken repointed by setParams, e.g. a botched token migration; minter revocation; mint cap reached), every retry reverts forever and a corrected payload is rejected by the hash check. The claim is permanently and silently lost: L1 emitted UserClaimed and advanced lastClaim, so no L1 observable shows the failure, and L1 data cannot even enumerate the victims. Loss per failed claim = the user's full pendingRewards; the stETH pool alone emits ~2,856.8 MOR/day (~$2,027.81/day at $0.70987/MOR, CoinGecko morpheusai, 2026-11-18), individual pending claims of 100 MOR = $70.99 are routine, and the path's live inbound nonce was 9,914, so a failure window hits production claim volume. CVSS 3.1: 6.5 (AV:N/AC:H/PR:N/UI:N/S:U/C:N/I:L/A:H).

PRECONDITIONS
A user claims rewards (normal flow), and the resulting L2 mint delivery fails persistently across retries for any configuration-class reason (rewardToken change via the owner's setParams, minter revocation on MOR, or cap). No attacker action and no privileged role is required for the loss to occur.

ATTACK
1. User calls DepositPool.claim; _claim zeroes pendingRewards and sets lastClaim, then sends the mint message (fire-and-forget).
2. The LayerZero delivery reaches L2MessageReceiver.lzReceive on Arbitrum.
3. _nonblockingLzReceive calls IMOR(rewardToken).mint(receiver, amount) and reverts (persistent failure state).
4. The blocking wrapper catches the failure and stores only keccak256(payload) in failedMessages; MessageFailed is emitted on L2 only.
5. Anyone may call retryMessage with the identical payload; it reverts at the same mint, forever.
6. A corrected payload (any byte changed) reverts on the payload-hash check, so no alternate recovery encoding exists.
7. On L1 nothing records the failure; the user's rewards are gone and their claim clock has advanced.

POC
Public Foundry project (linked repo): Arbitrum One fork pinned at block 525,256,398, run with `forge test`, against the real L2MessageReceiver proxy with its live config read at runtime. Control delivery through lzReceive mints 100 MOR to the claim receiver. With the mint path in a persistent-failure state (rewardToken pointed at a token whose mint reverts, a fork-only storage write standing in for the setParams-reachable configuration), a second delivery is swallowed without reverting, failedMessages holds exactly keccak256(payload), the receiver's balance does not move, retryMessage reverts twice, a modified payload reverts on the hash check, and the failed hash remains stored. 3/3 runs pass (identical gas 729,571). The L1 half is proven by the verified sources: the zero-before-send ordering in _claim and the absence of any recovery function in DepositPool, DistributorV2, and L1SenderV2. The only impersonation is the LayerZero gateway from the receiver's own config, the production delivery caller.

FIX
Record claims in flight on L1 (per-user sent-but-unacknowledged amount keyed by message nonce) and add an owner-or-timeout re-credit path that restores pendingRewards when no L2 mint confirmation exists; or make the L2 receiver able to execute a corrected payload under owner approval by storing the full payload (not only its hash) and adding an admin retryWithPayload that re-validates sender and chain. At minimum, emit and index an L1-visible failure signal so affected claims can be enumerated and made whole.
