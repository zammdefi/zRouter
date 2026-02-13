// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Test.sol";
import "../src/SubdomainRegistrar.sol";

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
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function registerSubdomainFor(string calldata label, uint256 parentId, address to)
        external
        returns (uint256);
    function renew(uint256 tokenId) external payable;
    function expiresAt(uint256 tokenId) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @title SubdomainRegistrar Fork Tests
/// @notice Tests SubdomainRegistrar against deployed NameNFT on mainnet fork.
///         Covers escrow mode, flash mode, ETH/ERC20 fees, gating, withdrawals,
///         and all revert paths.
contract SubdomainRegistrarTest is Test {
    address constant NAME_NFT_ADDR = 0x0000000000696760E15f265e828DB644A0c242EB;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDC_WHALE = 0x55FE002aefF02F77364de339a1292923A15844B8;

    INameNFTFull nameNFT;
    SubdomainRegistrar registrar;

    address controller;
    address buyer;
    address payout;

    uint256 parentId;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("main"));

        nameNFT = INameNFTFull(NAME_NFT_ADDR);
        registrar = new SubdomainRegistrar();

        controller = makeAddr("controller");
        buyer = makeAddr("buyer");
        payout = makeAddr("payout");

        vm.deal(controller, 10 ether);
        vm.deal(buyer, 10 ether);

        // Register a parent name for the controller via commit-reveal
        parentId = _registerName("subregtest", controller);
    }

    /* ═══════════════════ helpers ═══════════════════ */

    function _registerName(string memory label, address to) internal returns (uint256 tokenId) {
        bytes32 secret = keccak256(abi.encode(label, to));
        bytes32 commitment = nameNFT.makeCommitment(label, to, secret);

        vm.prank(to);
        nameNFT.commit(commitment);
        vm.warp(block.timestamp + 61);

        tokenId = nameNFT.computeId(string.concat(label, ".wei"));
        uint256 fee = nameNFT.getFee(bytes(label).length) + nameNFT.getPremium(tokenId);

        vm.prank(to);
        nameNFT.reveal{value: fee}(label, secret);

        assertEq(nameNFT.ownerOf(tokenId), to, "registration failed");
    }

    function _depositParent() internal {
        vm.startPrank(controller);
        nameNFT.approve(address(registrar), parentId);
        registrar.deposit(parentId);
        vm.stopPrank();
    }

    function _configureEscrowETH(uint256 price) internal {
        _depositParent();
        vm.prank(controller);
        registrar.configure(parentId, payout, address(0), price, true, address(0), 0);
    }

    function _configureFlashETH(uint256 price) internal {
        // Approve registrar for flash transfers
        vm.prank(controller);
        nameNFT.setApprovalForAll(address(registrar), true);

        vm.prank(controller);
        registrar.configure(parentId, payout, address(0), price, true, address(0), 0);
    }

    /* ═══════════════════ ESCROW MODE — deposit / withdraw ═══════════════════ */

    function testDeposit() public {
        vm.startPrank(controller);
        nameNFT.approve(address(registrar), parentId);
        registrar.deposit(parentId);
        vm.stopPrank();

        assertEq(nameNFT.ownerOf(parentId), address(registrar), "registrar holds parent");
        assertEq(registrar.escrowedController(parentId), controller, "controller recorded");
    }

    function testDepositViaSafeTransfer() public {
        vm.prank(controller);
        nameNFT.safeTransferFrom(controller, address(registrar), parentId);

        assertEq(nameNFT.ownerOf(parentId), address(registrar), "registrar holds parent");
        assertEq(registrar.escrowedController(parentId), controller, "controller recorded");
    }

    function testWithdrawParent() public {
        _depositParent();

        vm.prank(controller);
        registrar.withdrawParent(parentId, controller);

        assertEq(nameNFT.ownerOf(parentId), controller, "parent returned");
        assertEq(registrar.escrowedController(parentId), address(0), "escrow cleared");
    }

    function testWithdrawParentDisablesConfig() public {
        _configureEscrowETH(0.01 ether);

        vm.prank(controller);
        registrar.withdrawParent(parentId, controller);

        (, bool enabled,,,,,) = registrar.config(parentId);
        assertFalse(enabled, "config disabled after withdraw");
    }

    function testWithdrawToOther() public {
        _depositParent();
        address other = makeAddr("other");

        vm.prank(controller);
        registrar.withdrawParent(parentId, other);

        assertEq(nameNFT.ownerOf(parentId), other, "sent to other");
    }

    function testRevertDepositNotOwner() public {
        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.deposit(parentId);
    }

    function testRevertDepositAlreadyEscrowed() public {
        _depositParent();

        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.AlreadyEscrowed.selector);
        registrar.deposit(parentId);
    }

    function testRevertWithdrawNotController() public {
        _depositParent();

        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.withdrawParent(parentId, buyer);
    }

    function testRevertWithdrawNotEscrowed() public {
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.NotEscrowed.selector);
        registrar.withdrawParent(parentId, controller);
    }

    /* ═══════════════════ ESCROW MODE — registration with ETH fee ═══════════════════ */

    function testRegisterEscrowETH() public {
        uint256 price = 0.01 ether;
        _configureEscrowETH(price);

        vm.prank(buyer);
        uint256 subId = registrar.register{value: price}(parentId, "hello");

        assertEq(nameNFT.ownerOf(subId), buyer, "buyer owns subdomain");
        assertEq(registrar.ethBalance(payout), price, "payout credited");
    }

    function testRegisterEscrowETHRefundsExcess() public {
        uint256 price = 0.01 ether;
        _configureEscrowETH(price);

        uint256 balBefore = buyer.balance;

        vm.prank(buyer);
        registrar.register{value: 1 ether}(parentId, "refundme");

        // buyer spent exactly price (rest refunded)
        assertEq(balBefore - buyer.balance, price, "exact price deducted");
    }

    function testRegisterEscrowFree() public {
        _configureEscrowETH(0);

        vm.prank(buyer);
        uint256 subId = registrar.register(parentId, "freename");

        assertEq(nameNFT.ownerOf(subId), buyer, "buyer owns subdomain");
        assertEq(registrar.ethBalance(payout), 0, "no fee collected");
    }

    function testRegisterFor() public {
        _configureEscrowETH(0);
        address recipient = makeAddr("recipient");

        vm.prank(buyer);
        uint256 subId = registrar.registerFor(parentId, "gifted", recipient);

        assertEq(nameNFT.ownerOf(subId), recipient, "recipient owns subdomain");
    }

    function testRegisterMultipleSubdomains() public {
        _configureEscrowETH(0);

        vm.startPrank(buyer);
        uint256 sub1 = registrar.register(parentId, "first");
        uint256 sub2 = registrar.register(parentId, "second");
        uint256 sub3 = registrar.register(parentId, "third");
        vm.stopPrank();

        assertEq(nameNFT.ownerOf(sub1), buyer);
        assertEq(nameNFT.ownerOf(sub2), buyer);
        assertEq(nameNFT.ownerOf(sub3), buyer);
        assertTrue(sub1 != sub2 && sub2 != sub3, "unique IDs");
    }

    /* ═══════════════════ FLASH MODE — registration with ETH fee ═══════════════════ */

    function testRegisterFlashETH() public {
        uint256 price = 0.005 ether;
        _configureFlashETH(price);

        // Verify parent stays with controller
        assertEq(nameNFT.ownerOf(parentId), controller, "controller still owns parent");

        vm.prank(buyer);
        uint256 subId = registrar.register{value: price}(parentId, "flashsub");

        assertEq(nameNFT.ownerOf(subId), buyer, "buyer owns subdomain");
        assertEq(nameNFT.ownerOf(parentId), controller, "parent returned to controller");
        assertEq(registrar.ethBalance(payout), price, "payout credited");
    }

    function testRegisterFlashFree() public {
        _configureFlashETH(0);

        vm.prank(buyer);
        uint256 subId = registrar.register(parentId, "freeflash");

        assertEq(nameNFT.ownerOf(subId), buyer, "buyer owns subdomain");
        assertEq(nameNFT.ownerOf(parentId), controller, "parent returned");
    }

    /* ═══════════════════ ERC20 FEE MODE ═══════════════════ */

    function testRegisterEscrowERC20() public {
        uint256 price = 10e6; // 10 USDC
        _depositParent();

        vm.prank(controller);
        registrar.configure(parentId, payout, USDC, price, true, address(0), 0);

        // Fund buyer with USDC
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(buyer, 100e6);

        vm.startPrank(buyer);
        IERC20(USDC).approve(address(registrar), price);
        uint256 subId = registrar.register(parentId, "paidusdc");
        vm.stopPrank();

        assertEq(nameNFT.ownerOf(subId), buyer, "buyer owns subdomain");
        assertEq(IERC20(USDC).balanceOf(payout), price, "payout received USDC");
    }

    function testRevertERC20WithETH() public {
        _depositParent();
        vm.prank(controller);
        registrar.configure(parentId, payout, USDC, 10e6, true, address(0), 0);

        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(buyer, 100e6);

        vm.startPrank(buyer);
        IERC20(USDC).approve(address(registrar), 10e6);
        vm.expectRevert(SubdomainRegistrar.UnexpectedETH.selector);
        registrar.register{value: 1 ether}(parentId, "badeth");
        vm.stopPrank();
    }

    /* ═══════════════════ GATING ═══════════════════ */

    function testGateWithERC20Balance() public {
        uint256 minBalance = 50e6; // Need 50 USDC to register
        _depositParent();

        vm.prank(controller);
        registrar.configure(parentId, payout, address(0), 0, true, USDC, minBalance);

        // buyer without USDC → reverts
        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.GateFailed.selector);
        registrar.register(parentId, "gated");

        // Fund buyer with enough USDC
        vm.prank(USDC_WHALE);
        IERC20(USDC).transfer(buyer, 50e6);

        // Now succeeds
        vm.prank(buyer);
        uint256 subId = registrar.register(parentId, "gated");
        assertEq(nameNFT.ownerOf(subId), buyer);
    }

    /* ═══════════════════ CONFIGURE VALIDATION ═══════════════════ */

    function testConfigureEmitEvent() public {
        _depositParent();

        vm.expectEmit(true, true, true, true);
        emit SubdomainRegistrar.ParentConfigured(
            parentId, controller, payout, address(0), 0.01 ether, address(0), 0, true
        );

        vm.prank(controller);
        registrar.configure(parentId, payout, address(0), 0.01 ether, true, address(0), 0);
    }

    function testConfigureDefaultPayout() public {
        _depositParent();

        vm.prank(controller);
        registrar.configure(parentId, address(0), address(0), 0, true, address(0), 0);

        (address cfgController,,,,,, address cfgPayout) = registrar.config(parentId);
        assertEq(cfgController, controller);
        assertEq(cfgPayout, controller, "payout defaults to controller");
    }

    function testRevertConfigureNotController() public {
        _depositParent();

        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.configure(parentId, payout, address(0), 0, true, address(0), 0);
    }

    function testRevertConfigureBadGate() public {
        _depositParent();

        // gate token set but minBalance=0
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.BadGateConfig.selector);
        registrar.configure(parentId, payout, address(0), 0, true, USDC, 0);

        // gate token zero but minBalance>0
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.BadGateConfig.selector);
        registrar.configure(parentId, payout, address(0), 0, true, address(0), 100);
    }

    function testRevertConfigurePriceTooLarge() public {
        _depositParent();

        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.ValueTooLarge.selector);
        registrar.configure(
            parentId, payout, address(0), uint256(type(uint96).max) + 1, true, address(0), 0
        );
    }

    /* ═══════════════════ DISABLE ═══════════════════ */

    function testDisable() public {
        _configureEscrowETH(0.01 ether);

        vm.prank(controller);
        registrar.disable(parentId);

        (, bool enabled,,,,,) = registrar.config(parentId);
        assertFalse(enabled);

        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.NotEnabled.selector);
        registrar.register{value: 0.01 ether}(parentId, "nope");
    }

    function testRevertDisableNotController() public {
        _configureEscrowETH(0);

        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.disable(parentId);
    }

    /* ═══════════════════ REGISTRATION REVERTS ═══════════════════ */

    function testRevertRegisterNotEnabled() public {
        _depositParent();
        // configured but not enabled
        vm.prank(controller);
        registrar.configure(parentId, payout, address(0), 0, false, address(0), 0);

        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.NotEnabled.selector);
        registrar.register(parentId, "nope");
    }

    function testRevertRegisterInsufficientFee() public {
        _configureEscrowETH(1 ether);

        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.InsufficientFee.selector);
        registrar.register{value: 0.5 ether}(parentId, "cheap");
    }

    function testRevertRegisterStaleController() public {
        _configureFlashETH(0);

        // Transfer parent away from controller → stale
        vm.prank(controller);
        nameNFT.transferFrom(controller, buyer, parentId);

        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.StaleController.selector);
        registrar.register(parentId, "stale");
    }

    /* ═══════════════════ ETH WITHDRAWAL ═══════════════════ */

    function testWithdrawETH() public {
        uint256 price = 0.05 ether;
        _configureEscrowETH(price);

        // Register to accrue fees
        vm.prank(buyer);
        registrar.register{value: price}(parentId, "payme");

        assertEq(registrar.ethBalance(payout), price);

        uint256 balBefore = payout.balance;
        vm.prank(payout);
        registrar.withdrawETH(address(0)); // address(0) → defaults to msg.sender

        assertEq(payout.balance - balBefore, price, "payout received ETH");
        assertEq(registrar.ethBalance(payout), 0, "balance zeroed");
    }

    function testWithdrawETHToOther() public {
        uint256 price = 0.02 ether;
        _configureEscrowETH(price);

        vm.prank(buyer);
        registrar.register{value: price}(parentId, "other");

        address dest = makeAddr("dest");
        vm.prank(payout);
        registrar.withdrawETH(dest);

        assertEq(dest.balance, price, "dest received ETH");
    }

    function testWithdrawETHZeroBalance() public {
        // Should not revert, just emit with amount=0
        vm.prank(buyer);
        registrar.withdrawETH(address(0));
    }

    /* ═══════════════════ EVENTS ═══════════════════ */

    function testRegisterEmitsEvent() public {
        _configureEscrowETH(0.01 ether);

        vm.prank(buyer);
        vm.expectEmit(true, false, true, false);
        emit SubdomainRegistrar.SubdomainRegistered(
            parentId, 0, buyer, buyer, address(0), 0.01 ether, "eventsub"
        );
        registrar.register{value: 0.01 ether}(parentId, "eventsub");
    }

    function testDepositEmitsEvent() public {
        vm.startPrank(controller);
        nameNFT.approve(address(registrar), parentId);

        vm.expectEmit(true, true, false, false);
        emit SubdomainRegistrar.Deposited(parentId, controller);
        registrar.deposit(parentId);
        vm.stopPrank();
    }

    function testWithdrawEmitsEvent() public {
        _depositParent();

        vm.expectEmit(true, true, true, false);
        emit SubdomainRegistrar.Withdrawn(parentId, controller, controller);

        vm.prank(controller);
        registrar.withdrawParent(parentId, controller);
    }

    /* ═══════════════════ EDGE: re-configure after escrow ═══════════════════ */

    function testReconfigureWhileEscrowed() public {
        _configureEscrowETH(0.01 ether);

        // Change price
        vm.prank(controller);
        registrar.configure(parentId, payout, address(0), 0.05 ether, true, address(0), 0);

        // Old price fails
        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.InsufficientFee.selector);
        registrar.register{value: 0.01 ether}(parentId, "reconf");

        // New price works
        vm.prank(buyer);
        uint256 subId = registrar.register{value: 0.05 ether}(parentId, "reconf");
        assertEq(nameNFT.ownerOf(subId), buyer);
    }

    /* ═══════════════════ EDGE: withdraw, re-deposit, re-register ═══════════════════ */

    function testWithdrawReDepositCycle() public {
        _configureEscrowETH(0);

        vm.prank(buyer);
        uint256 sub1 = registrar.register(parentId, "cycle1");
        assertEq(nameNFT.ownerOf(sub1), buyer);

        // Withdraw
        vm.prank(controller);
        registrar.withdrawParent(parentId, controller);

        // Re-deposit and re-configure
        _depositParent();
        vm.prank(controller);
        registrar.configure(parentId, payout, address(0), 0, true, address(0), 0);

        // Register another subdomain
        vm.prank(buyer);
        uint256 sub2 = registrar.register(parentId, "cycle2");
        assertEq(nameNFT.ownerOf(sub2), buyer);
    }

    /* ═══════════════════ INTEGRATION: subdomain resolves on NameNFT ═══════════════════ */

    function testSubdomainResolvesCorrectly() public {
        _configureEscrowETH(0);

        vm.prank(buyer);
        uint256 subId = registrar.register(parentId, "resolve");

        // Verify the subdomain is active and resolvable
        address resolved = INameNFTFull(NAME_NFT_ADDR).ownerOf(subId);
        assertEq(resolved, buyer, "subdomain owned by buyer");
    }

    /* ═══════════════════════════════════════════════════════════════
                          SECURITY: DRAIN PREVENTION
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Flash mode: _safeMint fires onERC721Received on `to` while
    ///         the parent is held by the registrar. A malicious receiver
    ///         must not be able to steal the parent during this callback.
    function testFlashModeParentSafeDuringSafeMintCallback() public {
        _configureFlashETH(0);

        // Deploy attacker that tries to steal the parent during onERC721Received
        FlashThief thief = new FlashThief(registrar, nameNFT, parentId);

        // registerFor sends subdomain to the thief contract, triggering callback
        vm.prank(buyer);
        registrar.registerFor(parentId, "flashthief", address(thief));

        // Parent must still be with the controller, not the thief
        assertEq(nameNFT.ownerOf(parentId), controller, "parent safe after flash");
        assertFalse(thief.stoleParent(), "thief did not steal parent");
    }

    /// @notice Escrow mode: _safeMint callback must not allow stealing
    ///         the escrowed parent.
    function testEscrowParentSafeDuringSafeMintCallback() public {
        _configureEscrowETH(0);

        EscrowThief thief = new EscrowThief(registrar, nameNFT, parentId, controller);

        vm.prank(buyer);
        registrar.registerFor(parentId, "escrowthief", address(thief));

        // Parent must still be escrowed
        assertEq(nameNFT.ownerOf(parentId), address(registrar), "parent still escrowed");
        assertEq(registrar.escrowedController(parentId), controller, "controller unchanged");
        assertFalse(thief.stoleParent(), "thief did not steal parent");
    }

    /// @notice Reentrancy via _safeMint: malicious receiver tries to
    ///         re-enter register() to mint infinite free subdomains.
    function testReentrancyViaReceiverBlocked() public {
        _configureEscrowETH(0.01 ether);

        ReentrantBuyer reentrant = new ReentrantBuyer(registrar, parentId);
        vm.deal(address(reentrant), 10 ether);

        // First registration triggers callback, callback tries register() → Reentrancy
        vm.prank(address(reentrant));
        reentrant.attack{value: 0.01 ether}();

        // Only ONE subdomain was minted (the legitimate one), reentrant call failed
        assertEq(reentrant.mintCount(), 1, "only 1 subdomain minted");
        assertEq(registrar.ethBalance(payout), 0.01 ether, "only 1 fee collected");
    }

    /// @notice Malicious ERC20 feeToken tries to re-enter during fee collection.
    ///         At this point the parent is already returned (flash) or still escrowed.
    function testReentrancyViaMaliciousERC20Blocked() public {
        _depositParent();

        // Deploy malicious token that re-enters on transferFrom
        MaliciousERC20 evil = new MaliciousERC20(registrar, parentId);

        vm.prank(controller);
        registrar.configure(parentId, payout, address(evil), 1, true, address(0), 0);

        evil.mint(buyer, 100);

        vm.startPrank(buyer);
        evil.approve(address(registrar), 100);
        // The evil token's transferFrom tries to re-enter register → Reentrancy revert
        // But the outer call still succeeds because the evil token catches its own revert
        registrar.register(parentId, "eviltoken");
        vm.stopPrank();

        // Parent still escrowed, attacker got nothing extra
        assertEq(nameNFT.ownerOf(parentId), address(registrar), "parent still escrowed");
        assertEq(registrar.escrowedController(parentId), controller);
    }

    /// @notice Attacker cannot configure someone else's escrowed parent.
    function testCannotHijackEscrowedConfig() public {
        _configureEscrowETH(0.01 ether);

        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.configure(parentId, buyer, address(0), 0, true, address(0), 0);

        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.disable(parentId);
    }

    /// @notice Attacker cannot configure a flash-mode parent they don't own.
    function testCannotHijackFlashConfig() public {
        _configureFlashETH(0.01 ether);

        // Transfer parent to attacker
        vm.prank(controller);
        nameNFT.transferFrom(controller, buyer, parentId);

        // buyer now owns parent but old config has controller as controller
        // buyer can configure (they're now the owner via _controllerOf)
        // but the OLD config's controller field is stale, so register reverts
        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.StaleController.selector);
        registrar.register{value: 0.01 ether}(parentId, "hijack");
    }

    /// @notice After escrow withdrawal, the original controller can no longer
    ///         register subdomains even if config.enabled was true before.
    function testWithdrawKillsRegistration() public {
        _configureEscrowETH(0.01 ether);

        vm.prank(controller);
        registrar.withdrawParent(parentId, controller);

        // Config is disabled by withdrawParent
        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.NotEnabled.selector);
        registrar.register{value: 0.01 ether}(parentId, "dead");
    }

    /// @notice Flash mode: setApprovalForAll does NOT let the registrar
    ///         steal OTHER NFTs from the controller — only the configured
    ///         parentId can be flash-borrowed.
    function testFlashCannotStealOtherNFTs() public {
        // Register a second parent for the same controller
        uint256 otherParentId = _registerName("othername", controller);

        // Controller approves registrar for ALL (for flash on first parent)
        vm.prank(controller);
        nameNFT.setApprovalForAll(address(registrar), true);

        // Configure only the first parent
        vm.prank(controller);
        registrar.configure(parentId, payout, address(0), 0, true, address(0), 0);

        // Attacker tries to register using otherParentId → not configured/enabled
        vm.prank(buyer);
        vm.expectRevert(SubdomainRegistrar.NotEnabled.selector);
        registrar.register(otherParentId, "stolen");

        // otherParentId still with controller
        assertEq(nameNFT.ownerOf(otherParentId), controller);
    }

    /// @notice Verify accumulated ETH fees cannot be drained by anyone
    ///         other than the payout address.
    function testETHBalanceIsolation() public {
        uint256 price = 0.1 ether;
        _configureEscrowETH(price);

        vm.prank(buyer);
        registrar.register{value: price}(parentId, "feesub");

        // Attacker cannot withdraw payout's balance
        assertEq(registrar.ethBalance(buyer), 0, "buyer has no balance");

        vm.prank(buyer);
        registrar.withdrawETH(buyer);
        assertEq(buyer.balance, 10 ether - price, "buyer got nothing extra");

        // Payout balance is intact
        assertEq(registrar.ethBalance(payout), price, "payout balance preserved");
    }

    /// @notice Flash mode: parent is always returned even after many
    ///         sequential registrations.
    function testFlashAlwaysReturnsParent() public {
        _configureFlashETH(0.001 ether);

        for (uint256 i; i < 5; i++) {
            string memory label = string(abi.encodePacked("seq", bytes1(uint8(0x61 + i))));
            vm.prank(buyer);
            registrar.register{value: 0.001 ether}(parentId, label);

            assertEq(
                nameNFT.ownerOf(parentId), controller, "parent returned after each registration"
            );
        }
    }

    /* ═══════════════════════════════════════════════════════════════
                     PARENT EXPIRY EDGE CASES
       ═══════════════════════════════════════════════════════════════ */

    /// @notice After parent expires, escrow registration reverts (NameNFT Expired).
    function testExpiredParentBlocksEscrowRegistration() public {
        _configureEscrowETH(0);

        // Warp past expiry (365 days)
        vm.warp(block.timestamp + 366 days);

        vm.prank(buyer);
        vm.expectRevert(); // NameNFT: Expired
        registrar.register(parentId, "expired");
    }

    /// @notice After parent expires, flash registration reverts because
    ///         NameNFT._beforeTokenTransfer blocks transfers of inactive tokens.
    function testExpiredParentBlocksFlashRegistration() public {
        _configureFlashETH(0);

        vm.warp(block.timestamp + 366 days);

        vm.prank(buyer);
        vm.expectRevert(); // NameNFT: Expired (on transferFrom)
        registrar.register(parentId, "expired");
    }

    /// @notice CRITICAL: Expired escrowed parent cannot be withdrawn because
    ///         NameNFT blocks transfers of inactive tokens. Controller must
    ///         renew the parent FIRST, then withdraw.
    function testExpiredEscrowedParentBlocksWithdraw() public {
        _depositParent();

        // Warp past expiry but within grace (90 days grace)
        vm.warp(block.timestamp + 366 days);

        // Withdraw attempt fails — parent is inactive, transfer blocked
        vm.prank(controller);
        vm.expectRevert(); // NameNFT: Expired (on transferFrom)
        registrar.withdrawParent(parentId, controller);

        // Parent is still locked in the registrar
        assertEq(nameNFT.ownerOf(parentId), address(registrar));
    }

    /// @notice Rescue path: controller renews the escrowed parent (renew is
    ///         permissionless), then withdraws successfully.
    function testRenewEscrowedParentThenWithdraw() public {
        _depositParent();

        // Warp past expiry, within grace
        vm.warp(block.timestamp + 366 days);

        // Withdraw fails
        vm.prank(controller);
        vm.expectRevert();
        registrar.withdrawParent(parentId, controller);

        // Renew is permissionless — anyone can call it, doesn't check ownership
        uint256 fee = INameNFTFull(NAME_NFT_ADDR).getFee(bytes("subregtest").length);
        vm.prank(controller);
        INameNFTFull(NAME_NFT_ADDR).renew{value: fee}(parentId);

        // Now withdraw works
        vm.prank(controller);
        registrar.withdrawParent(parentId, controller);

        assertEq(nameNFT.ownerOf(parentId), controller, "parent rescued");
    }

    /// @notice If parent expires past grace period, renewal also fails.
    ///         The escrowed parent is permanently stuck (but functionally dead).
    function testExpiredPastGraceParentPermanentlyStuck() public {
        _depositParent();

        // Warp past expiry + grace (365 + 90 + 1 days)
        vm.warp(block.timestamp + 456 days);

        // Renew fails — past grace
        uint256 fee = INameNFTFull(NAME_NFT_ADDR).getFee(bytes("subregtest").length);
        vm.prank(controller);
        vm.expectRevert(); // NameNFT: Expired (past grace)
        INameNFTFull(NAME_NFT_ADDR).renew{value: fee}(parentId);

        // Withdraw also fails
        vm.prank(controller);
        vm.expectRevert();
        registrar.withdrawParent(parentId, controller);

        // Parent is stuck but functionally dead — can be re-registered by anyone
        // (NameNFT._register burns the old token from registrar during re-registration)
    }

    /// @notice Registration still works right up to the expiry boundary.
    function testRegistrationWorksUntilExpiryBoundary() public {
        _configureEscrowETH(0);

        // Warp to exactly expiresAt (365 days from registration)
        // _isActive: block.timestamp <= record.expiresAt → true at boundary
        vm.warp(block.timestamp + 365 days);

        vm.prank(buyer);
        uint256 subId = registrar.register(parentId, "boundary");
        assertEq(nameNFT.ownerOf(subId), buyer, "works at exact expiry boundary");
    }

    /// @notice Registration fails 1 second after expiry.
    function testRegistrationFailsOneSecondAfterExpiry() public {
        _configureEscrowETH(0);

        vm.warp(block.timestamp + 365 days + 1);

        vm.prank(buyer);
        vm.expectRevert();
        registrar.register(parentId, "onesecond");
    }

    /* ═══════════════════════════════════════════════════════════════
                     ADDITIONAL EDGE CASES
       ═══════════════════════════════════════════════════════════════ */

    /// @notice onERC721Received rejects NFTs from contracts other than NameNFT.
    function testOnERC721ReceivedRejectsNonNameNFT() public {
        vm.prank(address(0xdead));
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.onERC721Received(address(0), buyer, 1, "");
    }

    /// @notice Two different parents from different controllers are fully
    ///         isolated — one controller cannot affect the other's config
    ///         or registration.
    function testMultipleParentsIsolation() public {
        address controller2 = makeAddr("controller2");
        vm.deal(controller2, 10 ether);

        uint256 parentId2 = _registerName("otherdomain", controller2);

        // Deposit both
        _depositParent(); // parentId → controller
        vm.startPrank(controller2);
        nameNFT.approve(address(registrar), parentId2);
        registrar.deposit(parentId2);
        registrar.configure(parentId2, controller2, address(0), 0.02 ether, true, address(0), 0);
        vm.stopPrank();

        vm.prank(controller);
        registrar.configure(parentId, payout, address(0), 0.01 ether, true, address(0), 0);

        // Controller cannot touch controller2's parent
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.configure(parentId2, controller, address(0), 0, true, address(0), 0);

        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.withdrawParent(parentId2, controller);

        // Both work independently
        vm.prank(buyer);
        uint256 sub1 = registrar.register{value: 0.01 ether}(parentId, "isoone");

        vm.prank(buyer);
        uint256 sub2 = registrar.register{value: 0.02 ether}(parentId2, "isotwo");

        assertEq(nameNFT.ownerOf(sub1), buyer);
        assertEq(nameNFT.ownerOf(sub2), buyer);

        // Fees go to correct payouts
        assertEq(registrar.ethBalance(payout), 0.01 ether);
        assertEq(registrar.ethBalance(controller2), 0.02 ether);
    }

    /// @notice Registering the same label twice: the second registration
    ///         overwrites the first (NameNFT allows parent owner to reclaim).
    function testSubdomainOverwrite() public {
        _configureEscrowETH(0);

        vm.prank(buyer);
        uint256 subId1 = registrar.register(parentId, "overwrite");
        assertEq(nameNFT.ownerOf(subId1), buyer);

        // Register same label again to a different address
        address other = makeAddr("other");
        vm.prank(buyer);
        uint256 subId2 = registrar.registerFor(parentId, "overwrite", other);

        // Same token ID (deterministic hash), new owner
        assertEq(subId1, subId2, "same token ID");
        assertEq(nameNFT.ownerOf(subId2), other, "overwritten to new owner");
    }

    /// @notice registerFor with to=address(0) reverts (NameNFT _safeMint rejects).
    function testRegisterToZeroReverts() public {
        _configureEscrowETH(0);

        vm.prank(buyer);
        vm.expectRevert(); // ERC721: mint to zero address
        registrar.registerFor(parentId, "tozero", address(0));
    }

    /* ═══════════════════════════════════════════════════════════════
                     CLEAR STALE ESCROW
       ═══════════════════════════════════════════════════════════════ */

    /// @notice Full lifecycle via deposit() path: escrow → expire past grace →
    ///         re-register by new owner → stale escrow blocks deposit →
    ///         permissionless clearStaleEscrow → new owner deposits.
    function testClearStaleEscrowUnblocksNewOwner() public {
        _depositParent();

        // Warp past expiry + grace (365 + 90 + 1 days)
        vm.warp(block.timestamp + 456 days);

        // Re-register the same name with a different owner
        // (needs extra ETH for premium after expiry)
        address newOwner = makeAddr("newOwner");
        vm.deal(newOwner, 200 ether);
        uint256 reRegisteredId = _registerName("subregtest", newOwner);

        // Same tokenId (deterministic based on name)
        assertEq(reRegisteredId, parentId, "same tokenId after re-registration");
        assertEq(nameNFT.ownerOf(parentId), newOwner, "newOwner holds parent");

        // Stale escrow record still exists
        assertEq(registrar.escrowedController(parentId), controller, "stale record persists");

        // New owner CANNOT deposit via deposit() — AlreadyEscrowed
        vm.startPrank(newOwner);
        nameNFT.approve(address(registrar), parentId);
        vm.expectRevert(SubdomainRegistrar.AlreadyEscrowed.selector);
        registrar.deposit(parentId);
        vm.stopPrank();

        // New owner permissionlessly clears stale escrow (anyone can call)
        vm.expectEmit(true, true, false, false);
        emit SubdomainRegistrar.StaleEscrowCleared(parentId, controller);
        vm.prank(newOwner);
        registrar.clearStaleEscrow(parentId);

        assertEq(registrar.escrowedController(parentId), address(0), "escrow cleared");
        (, bool enabled,,,,,) = registrar.config(parentId);
        assertFalse(enabled, "config disabled after clear");

        // New owner can now deposit
        vm.startPrank(newOwner);
        registrar.deposit(parentId);
        vm.stopPrank();

        assertEq(registrar.escrowedController(parentId), newOwner, "newOwner is controller");
        assertEq(nameNFT.ownerOf(parentId), address(registrar), "registrar holds parent");
    }

    /// @notice safeTransferFrom path: stale escrow is overwritten by new depositor.
    ///         This is the primary defense against the theft vector where a malicious
    ///         old controller refuses to clear.
    function testSafeTransferOverwritesStaleEscrow() public {
        _depositParent();

        vm.warp(block.timestamp + 456 days);

        address newOwner = makeAddr("newOwner");
        vm.deal(newOwner, 200 ether);
        _registerName("subregtest", newOwner);

        // Stale record points to old controller
        assertEq(registrar.escrowedController(parentId), controller);

        // New owner deposits via safeTransferFrom — overwrites stale record
        vm.prank(newOwner);
        nameNFT.safeTransferFrom(newOwner, address(registrar), parentId);

        // New owner is now the controller, NOT the old one
        assertEq(registrar.escrowedController(parentId), newOwner, "overwritten to newOwner");
        assertEq(nameNFT.ownerOf(parentId), address(registrar), "registrar holds parent");

        // Old controller CANNOT withdraw
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.withdrawParent(parentId, controller);
    }

    /// @notice CRITICAL THEFT PREVENTION: old controller cannot steal a re-registered
    ///         name deposited via safeTransferFrom. The overwrite in onERC721Received
    ///         ensures the new depositor is always recorded as controller.
    function testOldControllerCannotStealReRegisteredName() public {
        _depositParent();
        vm.warp(block.timestamp + 456 days);

        address newOwner = makeAddr("newOwner");
        vm.deal(newOwner, 200 ether);
        _registerName("subregtest", newOwner);

        // New owner deposits via safeTransferFrom
        vm.prank(newOwner);
        nameNFT.safeTransferFrom(newOwner, address(registrar), parentId);

        // Old controller tries every path to steal:

        // 1. withdrawParent → fails (not controller)
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.withdrawParent(parentId, controller);

        // 2. configure → fails (not controller)
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.NotAuthorized.selector);
        registrar.configure(parentId, controller, address(0), 0, true, address(0), 0);

        // 3. clearStaleEscrow → fails (registrar still holds it)
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.AlreadyEscrowed.selector);
        registrar.clearStaleEscrow(parentId);

        // New owner retains full control
        vm.prank(newOwner);
        registrar.withdrawParent(parentId, newOwner);
        assertEq(nameNFT.ownerOf(parentId), newOwner, "newOwner safe");
    }

    /// @notice clearStaleEscrow is permissionless — any third party can clear.
    function testClearStaleEscrowByThirdParty() public {
        _depositParent();
        vm.warp(block.timestamp + 456 days);

        address newOwner = makeAddr("newOwner");
        vm.deal(newOwner, 200 ether);
        _registerName("subregtest", newOwner);

        // Random third party clears the stale record
        address anyone = makeAddr("anyone");
        vm.prank(anyone);
        registrar.clearStaleEscrow(parentId);

        assertEq(registrar.escrowedController(parentId), address(0));
    }

    /// @notice clearStaleEscrow reverts if no escrow record exists.
    function testRevertClearStaleEscrowNotEscrowed() public {
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.NotEscrowed.selector);
        registrar.clearStaleEscrow(parentId);
    }

    /// @notice clearStaleEscrow reverts if registrar still holds the parent.
    function testRevertClearStaleEscrowStillHeld() public {
        _depositParent();

        // Registrar still owns the parent — not stale
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.AlreadyEscrowed.selector);
        registrar.clearStaleEscrow(parentId);
    }

    /// @notice Expired past grace but not re-registered: ownerOf still returns
    ///         the registrar (NameNFT doesn't auto-burn). clearStaleEscrow correctly
    ///         blocks because the registrar technically still holds it. Clearing
    ///         becomes possible after re-registration (which burns the old token).
    function testClearStaleEscrowBlockedWhileExpiredButNotReRegistered() public {
        _depositParent();

        // Warp past expiry + grace
        vm.warp(block.timestamp + 456 days);

        // ownerOf still returns registrar — can't clear yet
        vm.prank(controller);
        vm.expectRevert(SubdomainRegistrar.AlreadyEscrowed.selector);
        registrar.clearStaleEscrow(parentId);
    }

    /// @notice NameNFT rejects invalid labels — registrar surfaces the revert.
    function testInvalidLabelReverts() public {
        _configureEscrowETH(0);

        // Label with dot (invalid in NameNFT)
        vm.prank(buyer);
        vm.expectRevert(); // NameNFT: InvalidName
        registrar.register(parentId, "bad.label");

        // Empty label
        vm.prank(buyer);
        vm.expectRevert(); // NameNFT: InvalidLength
        registrar.register(parentId, "");
    }
}

/* ═══════════════════════════════════════════════════════════════════
                     ATTACKER CONTRACTS
   ═══════════════════════════════════════════════════════════════════ */

/// @dev Receives subdomain NFT during flash mode, tries to transfer the
///      parent away from the registrar via NameNFT.transferFrom.
contract FlashThief {
    SubdomainRegistrar immutable reg;
    INameNFTFull immutable nft;
    uint256 immutable targetParent;
    bool public stoleParent;

    constructor(SubdomainRegistrar _reg, INameNFTFull _nft, uint256 _parent) {
        reg = _reg;
        nft = _nft;
        targetParent = _parent;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        // During this callback in flash mode, the parent is owned by the registrar.
        // Try to steal it via direct transferFrom (should fail — not approved).
        try nft.transferFrom(address(reg), address(this), targetParent) {
            stoleParent = true;
        } catch {}

        // Try to withdraw it (should fail — not escrowed controller, or Reentrancy)
        try reg.withdrawParent(targetParent, address(this)) {
            stoleParent = true;
        } catch {}

        return this.onERC721Received.selector;
    }
}

/// @dev Receives subdomain NFT during escrow mode, tries to steal the
///      escrowed parent via configure + withdrawParent.
contract EscrowThief {
    SubdomainRegistrar immutable reg;
    INameNFTFull immutable nft;
    uint256 immutable targetParent;
    address immutable realController;
    bool public stoleParent;

    constructor(SubdomainRegistrar _reg, INameNFTFull _nft, uint256 _parent, address _controller) {
        reg = _reg;
        nft = _nft;
        targetParent = _parent;
        realController = _controller;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        // Try to hijack the config (should fail — NotAuthorized)
        try reg.configure(targetParent, address(this), address(0), 0, true, address(0), 0) {
            // If configure somehow works, try to withdraw
            try reg.withdrawParent(targetParent, address(this)) {
                stoleParent = true;
            } catch {}
        } catch {}

        // Try direct NFT transfer (should fail — not approved)
        try nft.transferFrom(address(reg), address(this), targetParent) {
            stoleParent = true;
        } catch {}

        // Try to withdrawParent directly (should fail — not controller + Reentrancy)
        try reg.withdrawParent(targetParent, address(this)) {
            stoleParent = true;
        } catch {}

        return this.onERC721Received.selector;
    }
}

/// @dev Receives subdomain NFT and tries to re-enter register() to mint
///      more subdomains for free.
contract ReentrantBuyer {
    SubdomainRegistrar immutable reg;
    uint256 immutable targetParent;
    uint256 public mintCount;
    bool private _attacking;

    constructor(SubdomainRegistrar _reg, uint256 _parent) {
        reg = _reg;
        targetParent = _parent;
    }

    function attack() external payable {
        reg.register{value: 0.01 ether}(targetParent, "legit");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        mintCount++;

        // Try to re-enter register() — should revert with Reentrancy
        if (!_attacking) {
            _attacking = true;
            try reg.register{value: 0.01 ether}(targetParent, "reentrant") {
                mintCount++; // Should never reach here
            } catch {}
        }

        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @dev ERC20 that re-enters the registrar during transferFrom (fee collection).
contract MaliciousERC20 {
    SubdomainRegistrar immutable reg;
    uint256 immutable targetParent;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(SubdomainRegistrar _reg, uint256 _parent) {
        reg = _reg;
        targetParent = _parent;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] >= amount) {
            allowance[from][msg.sender] -= amount;
            balanceOf[from] -= amount;
            balanceOf[to] += amount;
        }

        // Try to re-enter register — should fail with Reentrancy
        try reg.register(targetParent, "reentered") {} catch {}

        // Try to withdraw parent — should fail with Reentrancy
        try reg.withdrawParent(targetParent, address(this)) {} catch {}

        return true;
    }
}
