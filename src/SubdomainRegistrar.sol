// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

interface IERC721Like {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

interface INameNFT is IERC721Like {
    function registerSubdomainFor(string calldata label, uint256 parentId, address to)
        external
        returns (uint256);
}

contract SubdomainRegistrar is IERC721Receiver {
    /*//////////////////////////////////////////////////////////////
                                   ERRORS
    //////////////////////////////////////////////////////////////*/
    error GateFailed();
    error NotEnabled();
    error Reentrancy();
    error NotEscrowed();
    error BadGateConfig();
    error NotAuthorized();
    error UnexpectedETH();
    error ValueTooLarge();
    error AlreadyEscrowed();
    error InsufficientFee();
    error StaleController();
    error ETHTransferFailed();
    error TransferFromFailed();

    /*//////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////*/
    event ParentConfigured(
        uint256 indexed parentId,
        address indexed controller,
        address indexed payout,
        address feeToken,
        uint256 price,
        address gateToken,
        uint256 minGateBalance,
        bool enabled
    );

    event Deposited(uint256 indexed parentId, address indexed controller);
    event Withdrawn(uint256 indexed parentId, address indexed controller, address indexed to);

    event SubdomainRegistered(
        uint256 indexed parentId,
        uint256 indexed subdomainId,
        address indexed buyer,
        address to,
        address feeToken,
        uint256 price,
        string label
    );

    event WithdrawETH(address indexed account, address indexed to, uint256 amount);
    event StaleEscrowCleared(uint256 indexed parentId, address indexed controller);

    /*//////////////////////////////////////////////////////////////
                                  STORAGE
    //////////////////////////////////////////////////////////////*/
    struct Config {
        address controller; // who controls config / receives parent back in flash mode
        bool enabled;
        address feeToken; // address(0)=ETH, else ERC20 token
        uint96 price; // fee amount (wei if ETH; token units if ERC20)
        address gateToken; // optional ERC20/ERC721 gate (balanceOf)
        uint96 minGateBalance; // minimum balance required (must be >0 if gateToken set)
        address payout; // receives ERC20 directly; ETH via ethBalance
    }

    INameNFT public constant name = INameNFT(0x0000000000696760E15f265e828DB644A0c242EB);

    mapping(uint256 => Config) public config;
    mapping(uint256 => address) public escrowedController; // nonzero => escrowed, controller recorded
    mapping(address => uint256) public ethBalance; // pull-payment ledger

    uint256 constant _REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21268;

    constructor() payable {}

    modifier nonReentrant() virtual {
        assembly ("memory-safe") {
            if tload(_REENTRANCY_GUARD_SLOT) {
                mstore(0x00, 0xab143c06)
                revert(0x1c, 0x04)
            }
            tstore(_REENTRANCY_GUARD_SLOT, address())
        }
        _;
        assembly ("memory-safe") {
            tstore(_REENTRANCY_GUARD_SLOT, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                               CONFIG
    //////////////////////////////////////////////////////////////*/

    function configure(
        uint256 parentId,
        address payout,
        address feeToken,
        uint256 price,
        bool enabled,
        address gateToken,
        uint256 minGateBalance
    ) public {
        if (_controllerOf(parentId) != msg.sender) revert NotAuthorized();
        if (payout == address(0)) payout = msg.sender;

        // prevent silent truncation into uint96
        if (price > type(uint96).max || minGateBalance > type(uint96).max) revert ValueTooLarge();

        // gate config sanity
        if (gateToken != address(0)) {
            if (minGateBalance == 0) revert BadGateConfig();
        } else {
            if (minGateBalance != 0) revert BadGateConfig();
        }

        config[parentId] = Config({
            controller: msg.sender,
            enabled: enabled,
            feeToken: feeToken,
            price: uint96(price),
            gateToken: gateToken,
            minGateBalance: uint96(minGateBalance),
            payout: payout
        });

        emit ParentConfigured(
            parentId, msg.sender, payout, feeToken, price, gateToken, minGateBalance, enabled
        );
    }

    function disable(uint256 parentId) public {
        if (_controllerOf(parentId) != msg.sender) revert NotAuthorized();

        Config storage c = config[parentId];
        c.controller = msg.sender; // refresh
        c.enabled = false;

        emit ParentConfigured(
            parentId,
            c.controller,
            c.payout,
            c.feeToken,
            uint256(c.price),
            c.gateToken,
            uint256(c.minGateBalance),
            c.enabled
        );
    }

    /*//////////////////////////////////////////////////////////////
                              ESCROW MODE
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 parentId) public nonReentrant {
        if (escrowedController[parentId] != address(0)) revert AlreadyEscrowed();
        if (name.ownerOf(parentId) != msg.sender) revert NotAuthorized();

        escrowedController[parentId] = msg.sender;
        name.transferFrom(msg.sender, address(this), parentId);

        emit Deposited(parentId, msg.sender);
    }

    function withdrawParent(uint256 parentId, address to) public nonReentrant {
        address controller = escrowedController[parentId];
        if (controller == address(0)) revert NotEscrowed();
        if (controller != msg.sender) revert NotAuthorized();

        if (to == address(0)) to = msg.sender;

        // Disable to avoid stale always-on config after custody changes.
        Config storage c = config[parentId];
        c.enabled = false;

        delete escrowedController[parentId];

        name.transferFrom(address(this), to, parentId);

        emit Withdrawn(parentId, msg.sender, to);
    }

    /// @dev Enables deposits via safeTransferFrom on the NameNFT.
    function onERC721Received(address, address from, uint256 tokenId, bytes calldata)
        public
        returns (bytes4)
    {
        if (msg.sender != address(name)) revert NotAuthorized();

        // Ignore mints (from=0). Also ignore internal moves (from=this).
        if (from == address(0) || from == address(this)) return this.onERC721Received.selector;

        escrowedController[tokenId] = from;
        emit Deposited(tokenId, from);

        return this.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                              REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function register(uint256 parentId, string calldata label)
        public
        payable
        returns (uint256 subId)
    {
        return registerFor(parentId, label, msg.sender);
    }

    /// @dev Gate + fee are evaluated against msg.sender (the payer).
    function registerFor(uint256 parentId, string calldata label, address to)
        public
        payable
        nonReentrant
        returns (uint256 subId)
    {
        Config memory c = config[parentId];
        if (!c.enabled) revert NotEnabled();

        // prevent sales after controller changes (transfer or escrow controller mismatch)
        address esc = escrowedController[parentId];
        address currentController = esc != address(0) ? esc : name.ownerOf(parentId);
        if (currentController != c.controller) revert StaleController();

        // optional gate (Solady-style balanceOf; returns 0 if not implemented)
        if (c.gateToken != address(0)) {
            if (balanceOf(c.gateToken, msg.sender) < uint256(c.minGateBalance)) {
                revert GateFailed();
            }
        }

        uint256 price = uint256(c.price);

        // fee checks
        if (c.feeToken == address(0)) {
            if (msg.value < price) revert InsufficientFee();
        } else {
            if (msg.value != 0) revert UnexpectedETH();
        }

        bool isEscrow = (esc != address(0));

        if (isEscrow) {
            // escrow mode: contract must own parentId
            if (name.ownerOf(parentId) != address(this)) revert NotEscrowed();
            subId = name.registerSubdomainFor(label, parentId, to);
        } else {
            // flash mode: pull, mint, return
            name.transferFrom(c.controller, address(this), parentId);
            subId = name.registerSubdomainFor(label, parentId, to);
            name.transferFrom(address(this), c.controller, parentId);
        }

        // collect fees after mint (tx reverts if ERC20 transferFrom fails)
        if (price != 0) {
            if (c.feeToken == address(0)) {
                ethBalance[c.payout] += price;
            } else {
                safeTransferFrom(c.feeToken, msg.sender, c.payout, price);
            }
        }

        // refund any extra ETH (self-send; caller controls recipient)
        if (c.feeToken == address(0)) {
            uint256 refund;
            unchecked {
                refund = msg.value - price;
            }
            if (refund != 0) safeTransferETH(msg.sender, refund);
        }

        emit SubdomainRegistered(parentId, subId, msg.sender, to, c.feeToken, price, label);
    }

    /*//////////////////////////////////////////////////////////////
                              ETH WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function withdrawETH(address to) public nonReentrant {
        uint256 amt = ethBalance[msg.sender];
        ethBalance[msg.sender] = 0;

        if (to == address(0)) to = msg.sender;

        if (amt != 0) safeTransferETH(to, amt);
        emit WithdrawETH(msg.sender, to, amt);
    }

    /*//////////////////////////////////////////////////////////////
                            STALE ESCROW
    //////////////////////////////////////////////////////////////*/

    /// @dev Permissionlessly clears a stale escrow record when the registrar
    ///      no longer holds the parent (e.g. expired past grace and re-registered).
    ///      Safe because if registrar doesn't own the parent, there's nothing to steal.
    function clearStaleEscrow(uint256 parentId) public {
        address esc = escrowedController[parentId];
        if (esc == address(0)) revert NotEscrowed();

        // Block only if registrar still owns it (legitimate escrow).
        // Allow clearing if ownerOf reverts (burned/non-existent) or returns someone else.
        (bool ok, bytes memory data) =
            address(name).staticcall(abi.encodeWithSelector(IERC721Like.ownerOf.selector, parentId));
        if (ok && data.length >= 32 && abi.decode(data, (address)) == address(this)) {
            revert AlreadyEscrowed();
        }

        delete escrowedController[parentId];
        config[parentId].enabled = false;

        emit StaleEscrowCleared(parentId, esc);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Current logical controller:
    ///      - if escrowed: escrowedController[parentId]
    ///      - else: NameNFT.ownerOf(parentId)
    function _controllerOf(uint256 parentId) internal view returns (address) {
        address esc = escrowedController[parentId];
        return esc != address(0) ? esc : name.ownerOf(parentId);
    }
}

function safeTransferETH(address to, uint256 amount) {
    assembly ("memory-safe") {
        if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
            mstore(0x00, 0xb12d13eb)
            revert(0x1c, 0x04)
        }
    }
}

function safeTransferFrom(address token, address from, address to, uint256 amount) {
    assembly ("memory-safe") {
        let m := mload(0x40)
        mstore(0x60, amount)
        mstore(0x40, to)
        mstore(0x2c, shl(96, from))
        mstore(0x0c, 0x23b872dd000000000000000000000000)
        let success := call(gas(), token, 0, 0x1c, 0x64, 0x00, 0x20)
        if iszero(and(eq(mload(0x00), 1), success)) {
            if iszero(lt(or(iszero(extcodesize(token)), returndatasize()), success)) {
                mstore(0x00, 0x7939f424)
                revert(0x1c, 0x04)
            }
        }
        mstore(0x60, 0)
        mstore(0x40, m)
    }
}

function balanceOf(address token, address account) view returns (uint256 amount) {
    assembly ("memory-safe") {
        mstore(0x14, account)
        mstore(0x00, 0x70a08231000000000000000000000000)
        amount := mul(
            mload(0x20),
            and(gt(returndatasize(), 0x1f), staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20))
        )
    }
}
