# BR-05 evidence

Scope enumeration: every contract touched is an Appendix A entry: DepositPool shared implementation 0xdB10dAEF167eA2233Ba6811457dD24D676FbD670 (behind all five Ethereum DepositPool proxies), Distributor 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A, L1SenderV2 0x2Efd4430489e1a05A89c2f51811aC661B7E5FF84 (Ethereum), L2MessageReceiver 0xd4a8ECcBe696295e68572A98b1aA70Aa9277d427 and MOR 0x092bAaDB7DEf4C3981454dD9c0A0D7FF07bCFc86 (Arbitrum). LayerZero endpoints are used only as the production delivery path, not as targets.

Live-state reads (read-only, threat-model phase, 2026-11-18):
- L1SenderV2 layerZeroConfig: gateway 0x66a71Dcef29A0fFBDBE3c6A460a3B5c225Cd675, receiver = Arbitrum L2MessageReceiver, chain 110, zro = 0x0.
- L2MessageReceiver config(): gateway 0x3c2269811836af69497e5f486a85d7316753cf62, sender = Ethereum L1SenderV2, chain 101. The two configs mirror each other exactly.
- MOR Arbitrum isMinter(L2MessageReceiver) = true; isMinter(L2TokenReceiverV2) = false; isMinter(ARB owner) = false.
- LayerZero Arbitrum inbound nonce for the L1SenderV2 path = 9,914 (production volume).
- Distributor wiring: chainLinkDataConsumer, l1Sender, rewardPool all point at the in-scope Appendix A addresses.

Code evidence (verified deployed sources, read in full):
- DepositPool._claim (DepositPool.sol lines 505-566): pendingRewards = 0 at line 549 and lastClaim set at line 553, both BEFORE sendMintMessage at lines ~557-563. Same shape in _claimReferrerTier (lines 568-602).
- DistributorV2.sendMintMessage (lines 496-506): pure forward, no claim record.
- L1SenderV2 full function list contains no retry/resend/ack/re-credit function; grep for failedMessages/MessageFailed across all three L1 sources: no matches.
- L2MessageReceiver: failedMessages stores keccak256(payload) only; retryMessage is hash-bound and re-executes the identical payload; _nonblockingLzReceive's only effect is IMOR(rewardToken).mint(user, amount).

Reproduction: poc/ run 3 times at pinned Arbitrum block 525,256,398: PASS, PASS, PASS (gas 729,571 each). Controls inside the test: a normal delivery mints 100 MOR (proves the harness and path are faithful), and a modified payload reverts on the hash check (proves no corrected re-delivery exists).

Full analysis and gate re-check: validation/BR-05/VERDICT.md. Threat model: recon/hypo-bridge.md (BR-05). Fence: recon/audit-fence.md (distinct from CodeHawks A3 H-01, where the mint executed to a wrong recipient; here it never executes).
