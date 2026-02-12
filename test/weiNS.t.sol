// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/zRouter.sol";

interface INameNFTFull {
    function makeCommitment(string calldata label, address owner, bytes32 secret)
        external
        pure
        returns (bytes32);
    function commit(bytes32 commitment) external;
    function reveal(string calldata label, bytes32 secret) external payable returns (uint256);
    function isAvailable(string calldata label, uint256 parentId) external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getFee(uint256 length) external view returns (uint256);
    function getPremium(uint256 tokenId) external view returns (uint256);
    function computeId(string calldata fullName) external pure returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IzQuoter {
    struct Quote {
        uint8 source;
        uint256 feeBps;
        uint256 amountIn;
        uint256 amountOut;
    }

    function buildBestSwap(
        address to,
        bool exactOut,
        address tokenIn,
        address tokenOut,
        uint256 swapAmount,
        uint256 slippageBps,
        uint256 deadline
    )
        external
        view
        returns (Quote memory best, bytes memory callData, uint256 amountLimit, uint256 msgValue);
}

/// @title weiNS Registration Tests
/// @notice Tests the commit-reveal flow as implemented in weiNS.html dapp
///         against the deployed zRouter and NameNFT on mainnet fork.
///
/// Commit-reveal scheme (per zRouter NatSpec / WNS-13 fix):
///   1. derivedSecret = keccak256(abi.encode(innerSecret, to))
///   2. commitment = NameNFT.makeCommitment(label, routerAddress, derivedSecret)
///   3. NameNFT.commit(commitment)
///   4. wait >= 60s
///   5. zRouter.revealName(label, innerSecret, to) — router re-derives secret internally
contract weiNSTest is Test {
    /* ─── deployed addresses (must match weiNS.html) ─── */
    address constant ROUTER = 0x000000000000FB114709235f1ccBFfb925F600e4;
    address constant NAME_NFT_ADDR = 0x0000000000696760E15f265e828DB644A0c242EB;
    address constant ZQUOTER = 0x82393672d597b70437b8Df275172A3B3e157AeB6;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDC_WHALE = 0x55FE002aefF02F77364de339a1292923A15844B8;
    address constant DAI_WHALE = 0x60FaAe176336dAb62e284Fe19B885B095d29fB7F;

    zRouter router;
    INameNFTFull nameNFT;
    IzQuoter quoter;

    address user;
    address attacker;

    string constant LABEL = "testtest";
    bytes32 constant INNER_SECRET = bytes32(uint256(0xdeadbeef));

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        router = zRouter(payable(ROUTER));
        nameNFT = INameNFTFull(NAME_NFT_ADDR);
        quoter = IzQuoter(ZQUOTER);

        user = makeAddr("user");
        attacker = makeAddr("attacker");

        vm.deal(user, 10 ether);
        vm.deal(attacker, 10 ether);

        assertTrue(nameNFT.isAvailable(LABEL, 0), "testtest.wei should be available");
    }

    /* ═══════════════════ helpers ═══════════════════ */

    /// @dev Replicates the dapp's doCommit() flow exactly:
    ///      innerSecret → derivedSecret = keccak256(encode(innerSecret, to))
    ///      commitment = makeCommitment(label, ROUTER, derivedSecret)
    function _commit(address registrant, string memory label, bytes32 innerSecret)
        internal
        returns (bytes32 commitment)
    {
        bytes32 derivedSecret = keccak256(abi.encode(innerSecret, registrant));
        commitment = nameNFT.makeCommitment(label, ROUTER, derivedSecret);
        vm.prank(registrant);
        nameNFT.commit(commitment);
    }

    function _fee(string memory label) internal view returns (uint256) {
        uint256 tokenId = nameNFT.computeId(string.concat(label, ".wei"));
        return nameNFT.getFee(bytes(label).length) + nameNFT.getPremium(tokenId);
    }

    function _tokenId(string memory label) internal view returns (uint256) {
        return nameNFT.computeId(string.concat(label, ".wei"));
    }

    /* ═══════════════════ ETH reveal ═══════════════════ */

    /// @notice Full ETH registration: commit → wait → reveal via router multicall
    function testRevealWithETH() public {
        // ── COMMIT (dapp doCommit) ──
        _commit(user, LABEL, INNER_SECRET);

        // ── WAIT MIN_COMMITMENT_AGE ──
        vm.warp(block.timestamp + 61);

        // ── REVEAL (dapp doReveal) ──
        uint256 total = _fee(LABEL);
        uint256 tokenId = _tokenId(LABEL);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.revealName, (LABEL, INNER_SECRET, user));
        calls[1] = abi.encodeCall(router.sweep, (address(0), 0, 0, user));

        uint256 ethBefore = user.balance;

        vm.prank(user);
        router.multicall{value: total}(calls);

        // ── ASSERTIONS ──
        assertEq(nameNFT.ownerOf(tokenId), user, "user owns name");
        assertEq(ethBefore - user.balance, total, "exact ETH spent");
        assertFalse(nameNFT.isAvailable(LABEL, 0), "name no longer available");
    }

    /* ═══════════════════ USDC atomic swap-to-reveal ═══════════════════ */

    /// @notice Full USDC registration: commit → wait → swap USDC→ETH → reveal
    ///         via router multicall (matches dapp doRevealWithUSDC flow).
    ///         Uses zQuoter.buildBestSwap for swap calldata, same as the dapp.
    function testRevealWithUSDC() public {
        string memory label = "testtestusdc";
        bytes32 innerSecret = bytes32(uint256(0xcafebabe));

        assertTrue(nameNFT.isAvailable(label, 0), "name should be available");

        // Fund user with USDC
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(user, 100e6);

        // ── COMMIT ──
        _commit(user, label, innerSecret);

        // ── WAIT ──
        vm.warp(block.timestamp + 61);

        // ── GET FEE + QUOTE ──
        uint256 totalEth = _fee(label);
        uint256 tokenId = _tokenId(label);
        uint256 deadline = block.timestamp + 1 hours;

        (IzQuoter.Quote memory best, bytes memory swapCalldata, uint256 maxUSDC,) = quoter.buildBestSwap(
            ROUTER, // to: router keeps ETH for revealName
            true, // exactOut
            USDC, // tokenIn
            address(0), // tokenOut (ETH)
            totalEth, // exact ETH needed
            200, // 2% slippage
            deadline
        );
        assertGt(best.amountIn, 0, "should have a USDC quote");

        // ── APPROVE USDC (dapp uses EIP-2612 permit, test uses approve) ──
        vm.prank(user);
        IERC20(USDC).approve(ROUTER, maxUSDC);

        // ── MULTICALL: [swap, revealName, sweep] ──
        bytes[] memory calls = new bytes[](3);
        calls[0] = swapCalldata;
        calls[1] = abi.encodeCall(router.revealName, (label, innerSecret, user));
        calls[2] = abi.encodeCall(router.sweep, (address(0), 0, 0, user));

        uint256 usdcBefore = IERC20(USDC).balanceOf(user);
        uint256 ethBefore = user.balance;

        vm.prank(user);
        router.multicall(calls); // no msg.value — ETH from swap

        // ── ASSERTIONS ──
        uint256 usdcSpent = usdcBefore - IERC20(USDC).balanceOf(user);

        assertEq(nameNFT.ownerOf(tokenId), user, "user owns name");
        assertGt(usdcSpent, 0, "spent USDC");
        assertLe(usdcSpent, maxUSDC, "within slippage limit");
        assertFalse(nameNFT.isAvailable(label, 0), "name taken");
        // excess ETH swept back
        assertGe(user.balance, ethBefore, "excess ETH returned");
    }

    /* ═══════════════════ security: front-run prevention ═══════════════════ */

    /// @notice WNS-13 fix: attacker who copies innerSecret from mempool
    ///         cannot steal the name by substituting their own `to` address.
    ///         The derived secret changes with `to`, so commitment won't match.
    function testFrontRunPrevented() public {
        // ── USER COMMITS ──
        _commit(user, LABEL, INNER_SECRET);
        vm.warp(block.timestamp + 61);

        uint256 total = _fee(LABEL);
        uint256 tokenId = _tokenId(LABEL);

        // ── ATTACKER intercepts innerSecret, tries reveal with own address ──
        bytes[] memory attackCalls = new bytes[](2);
        attackCalls[0] = abi.encodeCall(router.revealName, (LABEL, INNER_SECRET, attacker));
        attackCalls[1] = abi.encodeCall(router.sweep, (address(0), 0, 0, attacker));

        vm.prank(attacker);
        vm.expectRevert(); // CommitmentNotFound
        router.multicall{value: total}(attackCalls);

        // ── USER reveals successfully ──
        bytes[] memory userCalls = new bytes[](2);
        userCalls[0] = abi.encodeCall(router.revealName, (LABEL, INNER_SECRET, user));
        userCalls[1] = abi.encodeCall(router.sweep, (address(0), 0, 0, user));

        vm.prank(user);
        router.multicall{value: total}(userCalls);

        assertEq(nameNFT.ownerOf(tokenId), user, "user owns name, not attacker");
    }

    /// @notice Commitment cannot be replayed — attacker cannot commit
    ///         with the same derived secret since it binds to the user address.
    function testCommitBindsToRecipient() public {
        // User's derived secret
        bytes32 userSecret = keccak256(abi.encode(INNER_SECRET, user));
        // Attacker's derived secret (different!)
        bytes32 attackerSecret = keccak256(abi.encode(INNER_SECRET, attacker));

        // They must differ
        assertTrue(userSecret != attackerSecret, "secrets must differ per recipient");

        // Commitments differ too
        bytes32 userCommit = nameNFT.makeCommitment(LABEL, ROUTER, userSecret);
        bytes32 attackerCommit = nameNFT.makeCommitment(LABEL, ROUTER, attackerSecret);

        assertTrue(userCommit != attackerCommit, "commitments must differ per recipient");
    }

    /// @notice Commitment too new — cannot reveal before MIN_COMMITMENT_AGE
    function testCannotRevealTooEarly() public {
        _commit(user, LABEL, INNER_SECRET);
        uint256 total = _fee(LABEL);

        // Only wait 30s (need 60s)
        vm.warp(block.timestamp + 30);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.revealName, (LABEL, INNER_SECRET, user));
        calls[1] = abi.encodeCall(router.sweep, (address(0), 0, 0, user));

        vm.prank(user);
        vm.expectRevert(); // CommitmentTooNew
        router.multicall{value: total}(calls);
    }

    /// @notice Commitment expired — cannot reveal after MAX_COMMITMENT_AGE
    function testCannotRevealExpired() public {
        _commit(user, LABEL, INNER_SECRET);
        uint256 total = _fee(LABEL);

        // Wait past expiry (86400s + 1)
        vm.warp(block.timestamp + 86401);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.revealName, (LABEL, INNER_SECRET, user));
        calls[1] = abi.encodeCall(router.sweep, (address(0), 0, 0, user));

        vm.prank(user);
        vm.expectRevert(); // CommitmentTooOld
        router.multicall{value: total}(calls);
    }

    /* ═══════════════════ USDC with EIP-2612 permit ═══════════════════ */

    /// @notice Full USDC permit flow: sign EIP-2612 → multicall [permit, swap, reveal, sweep]
    ///         Matches the exact dapp doRevealWithUSDC() flow including permit signing.
    function testRevealWithUSDCPermit() public {
        string memory label = "testusdcpermit";
        bytes32 innerSecret = bytes32(uint256(0xaa));
        assertTrue(nameNFT.isAvailable(label, 0));

        // Create user with known private key for signing
        uint256 userPk = 0xA11CE;
        address userAddr = vm.addr(userPk);
        vm.deal(userAddr, 1 ether);
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(userAddr, 100e6);

        // ── COMMIT ──
        _commit(userAddr, label, innerSecret);
        vm.warp(block.timestamp + 61);

        // ── GET FEE + QUOTE ──
        uint256 totalEth = _fee(label);
        uint256 tokenId = _tokenId(label);
        uint256 deadline = block.timestamp + 1 hours;

        (IzQuoter.Quote memory best, bytes memory swapCalldata, uint256 maxUSDC,) =
            quoter.buildBestSwap(ROUTER, true, USDC, address(0), totalEth, 200, deadline);
        assertGt(best.amountIn, 0);

        // ── FETCH NONCE (same as dapp) ──
        (bool ok, bytes memory ret) =
            USDC.staticcall(abi.encodeWithSignature("nonces(address)", userAddr));
        assertTrue(ok);
        uint256 nonce = abi.decode(ret, (uint256));

        // ── SIGN EIP-2612 PERMIT (matches dapp's signTypedData) ──
        // Domain: { name: "USD Coin", version: "2", chainId: 1, verifyingContract: USDC }
        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("USD Coin"),
                keccak256("2"),
                uint256(1),
                USDC
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                userAddr,
                ROUTER,
                maxUSDC,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        // ── MULTICALL: [permit, swap, revealName, sweep] (exact dapp order) ──
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(router.permit, (USDC, maxUSDC, deadline, v, r, s));
        calls[1] = swapCalldata;
        calls[2] = abi.encodeCall(router.revealName, (label, innerSecret, userAddr));
        calls[3] = abi.encodeCall(router.sweep, (address(0), 0, 0, userAddr));

        uint256 usdcBefore = IERC20(USDC).balanceOf(userAddr);

        vm.prank(userAddr);
        router.multicall(calls);

        // ── ASSERTIONS ──
        assertEq(nameNFT.ownerOf(tokenId), userAddr, "user owns name");
        uint256 usdcSpent = usdcBefore - IERC20(USDC).balanceOf(userAddr);
        assertGt(usdcSpent, 0, "spent USDC");
        assertLe(usdcSpent, maxUSDC, "within slippage limit");
    }

    /* ═══════════════════ DAI with DAI-style permit ═══════════════════ */

    /// @notice Full DAI permit flow: sign DAI permit → multicall [permitDAI, swap, reveal, sweep]
    ///         Matches the exact dapp doRevealWithDAI() flow.
    ///         DAI uses non-standard permit: (holder, spender, nonce, expiry, allowed).
    function testRevealWithDAIPermit() public {
        string memory label = "testdaipermit";
        bytes32 innerSecret = bytes32(uint256(0xbb));
        assertTrue(nameNFT.isAvailable(label, 0));

        // Create user with known private key
        uint256 userPk = 0xB0B;
        address userAddr = vm.addr(userPk);
        vm.deal(userAddr, 1 ether);
        vm.prank(DAI_WHALE);
        IERC20(DAI).transfer(userAddr, 100e18);

        // ── COMMIT ──
        _commit(userAddr, label, innerSecret);
        vm.warp(block.timestamp + 61);

        // ── GET FEE + QUOTE ──
        uint256 totalEth = _fee(label);
        uint256 tokenId = _tokenId(label);
        uint256 deadline = block.timestamp + 1 hours;

        (IzQuoter.Quote memory best, bytes memory swapCalldata, uint256 maxDAI,) =
            quoter.buildBestSwap(ROUTER, true, DAI, address(0), totalEth, 200, deadline);
        assertGt(best.amountIn, 0);

        // ── FETCH NONCE ──
        (bool ok, bytes memory ret) =
            DAI.staticcall(abi.encodeWithSignature("nonces(address)", userAddr));
        assertTrue(ok);
        uint256 nonce = abi.decode(ret, (uint256));

        // ── SIGN DAI PERMIT ──
        // Domain: { name: "Dai Stablecoin", version: "1", chainId: 1, verifyingContract: DAI }
        // Types: Permit(holder,spender,nonce,expiry,allowed)
        bytes32 domainSep = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("Dai Stablecoin"),
                keccak256("1"),
                uint256(1),
                DAI
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)"
                ),
                userAddr,
                ROUTER,
                nonce,
                deadline,
                true
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSep, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPk, digest);

        // ── MULTICALL: [permitDAI, swap, revealName, sweep] (exact dapp order) ──
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(router.permitDAI, (nonce, deadline, v, r, s));
        calls[1] = swapCalldata;
        calls[2] = abi.encodeCall(router.revealName, (label, innerSecret, userAddr));
        calls[3] = abi.encodeCall(router.sweep, (address(0), 0, 0, userAddr));

        uint256 daiBefore = IERC20(DAI).balanceOf(userAddr);

        vm.prank(userAddr);
        router.multicall(calls);

        // ── ASSERTIONS ──
        assertEq(nameNFT.ownerOf(tokenId), userAddr, "user owns name");
        uint256 daiSpent = daiBefore - IERC20(DAI).balanceOf(userAddr);
        assertGt(daiSpent, 0, "spent DAI");
        assertLe(daiSpent, maxDAI, "within slippage limit");
    }
}
