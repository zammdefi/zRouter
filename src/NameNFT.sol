// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Base64} from "solady/utils/Base64.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "soledge/utils/ReentrancyGuard.sol";

/// @title NameNFT
/// @notice ENS-style naming system for .wei TLD with ERC721 ownership
/// @dev Token ID = uint256(namehash). ENS-compatible resolution.
///
/// Unicode Support:
/// - This contract validates UTF-8 encoding and accepts valid UTF-8 labels (including emoji)
/// - ASCII letters A-Z are automatically lowercased on-chain
/// - For proper Unicode normalization, callers SHOULD pre-normalize using ENSIP-15
/// - Off-chain: use adraffy/ens-normalize library or equivalent before calling
/// - Example: normalize("RaFFY🚴‍♂️") => "raffy🚴‍♂" (do this off-chain, then call contract)
contract NameNFT is ERC721, Ownable, ReentrancyGuard {
    using LibString for uint256;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error Expired();
    error TooDeep();
    error EmptyLabel();
    error InvalidName();
    error InvalidLength();
    error LengthMismatch();
    error NotParentOwner();
    error PremiumTooHigh();
    error InsufficientFee();
    error AlreadyCommitted();
    error CommitmentTooNew();
    error CommitmentTooOld();
    error AlreadyRegistered();
    error CommitmentNotFound();
    error DecayPeriodTooLong();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event NameRegistered(
        uint256 indexed tokenId, string label, address indexed owner, uint256 expiresAt
    );
    event SubdomainRegistered(uint256 indexed tokenId, uint256 indexed parentId, string label);
    event NameRenewed(uint256 indexed tokenId, uint256 newExpiresAt);
    event PrimaryNameSet(address indexed addr, uint256 indexed tokenId);
    event Committed(bytes32 indexed commitment, address indexed committer);

    // ENS-compatible resolver events (use bytes32 node for tooling compatibility)
    event AddrChanged(bytes32 indexed node, address addr);
    event ContenthashChanged(bytes32 indexed node, bytes contenthash);
    event AddressChanged(bytes32 indexed node, uint256 coinType, bytes addr);
    event TextChanged(bytes32 indexed node, string indexed key, string value);

    // Admin events
    event DefaultFeeChanged(uint256 fee);
    event LengthFeeChanged(uint256 indexed length, uint256 fee);
    event LengthFeeCleared(uint256 indexed length);
    event PremiumSettingsChanged(uint256 maxPremium, uint256 decayPeriod);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Namehash of "wei" TLD - kept public for off-chain tooling
    bytes32 public constant WEI_NODE =
        0xa82820059d5df798546bcc2985157a77c3eef25eba9ba01899927333efacbd6f;

    uint256 constant MAX_LABEL_LENGTH = 255;
    uint256 constant MIN_LABEL_LENGTH = 1;
    uint256 constant MIN_COMMITMENT_AGE = 60;
    uint256 constant MAX_COMMITMENT_AGE = 86400;
    uint256 constant REGISTRATION_PERIOD = 365 days;
    uint256 constant GRACE_PERIOD = 90 days;
    uint256 constant MAX_SUBDOMAIN_DEPTH = 10;
    uint256 constant COIN_TYPE_ETH = 60;
    uint256 constant MAX_PREMIUM_CAP = 10000 ether;
    uint256 constant MAX_DECAY_PERIOD = 3650 days;
    uint256 constant DEFAULT_FEE = 0.001 ether;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    struct NameRecord {
        string label;
        uint256 parent;
        uint64 expiresAt;
        uint64 epoch;
        uint64 parentEpoch;
    }

    uint256 public defaultFee;
    uint256 public maxPremium;
    uint256 public premiumDecayPeriod;

    mapping(uint256 => uint256) public lengthFees;
    mapping(uint256 => bool) public lengthFeeSet;
    mapping(uint256 => NameRecord) public records;
    mapping(uint256 => uint256) public recordVersion;
    mapping(bytes32 => uint256) public commitments;
    mapping(address => uint256) public primaryName;

    // Versioned resolver data
    mapping(uint256 => mapping(uint256 => address)) internal _resolvedAddress;
    mapping(uint256 => mapping(uint256 => bytes)) internal _contenthash;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => bytes))) internal _coinAddr;
    mapping(uint256 => mapping(uint256 => mapping(string => string))) internal _text;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() payable {
        _initializeOwner(tx.origin);
        defaultFee = DEFAULT_FEE;
        maxPremium = 100 ether;
        premiumDecayPeriod = 21 days;
    }

    /*//////////////////////////////////////////////////////////////
                             ERC721 METADATA
    //////////////////////////////////////////////////////////////*/

    function name() public pure override(ERC721) returns (string memory) {
        return "Wei Name Service";
    }

    function symbol() public pure override(ERC721) returns (string memory) {
        return "WEI";
    }

    /// @dev Blocks transfers of inactive tokens, but allows mint (from==0) and burn (to==0)
    /// This matches ENS behavior: expired names cannot be traded
    function _beforeTokenTransfer(address from, address to, uint256 tokenId)
        internal
        virtual
        override(ERC721)
    {
        // Allow mint and burn, block transfers of inactive tokens
        if (from != address(0) && to != address(0)) {
            if (!_isActive(tokenId)) revert Expired();
        }
    }

    function tokenURI(uint256 tokenId) public view override(ERC721) returns (string memory) {
        if (!_recordExists(tokenId)) revert TokenDoesNotExist();

        NameRecord storage record = records[tokenId];

        // Check for stale subdomain FIRST (parent epoch mismatch)
        if (record.parent != 0) {
            NameRecord storage parentRecord = records[record.parent];
            if (record.parentEpoch != parentRecord.epoch) {
                return string.concat(
                    "data:application/json;base64,",
                    Base64.encode(
                        bytes(
                            '{"name":"[Invalid]","description":"This subdomain is no longer valid.","image":"data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0MDAgNDAwIj48cmVjdCB3aWR0aD0iNDAwIiBoZWlnaHQ9IjQwMCIgZmlsbD0iIzk5OSIvPjx0ZXh0IHg9IjIwMCIgeT0iMjAwIiBmb250LWZhbWlseT0ic2Fucy1zZXJpZiIgZm9udC1zaXplPSIyNCIgdGV4dC1hbmNob3I9Im1pZGRsZSIgZmlsbD0iI2ZmZiI+W0ludmFsaWRdPC90ZXh0Pjwvc3ZnPg=="}'
                        )
                    )
                );
            }
        }

        // Check for expired (top-level or parent chain expired)
        if (!_isActive(tokenId)) {
            return string.concat(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        '{"name":"[Expired]","description":"This name has expired.","image":"data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0MDAgNDAwIj48cmVjdCB3aWR0aD0iNDAwIiBoZWlnaHQ9IjQwMCIgZmlsbD0iIzk5OSIvPjx0ZXh0IHg9IjIwMCIgeT0iMjAwIiBmb250LWZhbWlseT0ic2Fucy1zZXJpZiIgZm9udC1zaXplPSIyNCIgdGV4dC1hbmNob3I9Im1pZGRsZSIgZmlsbD0iI2ZmZiI+W0V4cGlyZWRdPC90ZXh0Pjwvc3ZnPg=="}'
                    )
                )
            );
        }

        string memory fullName = _buildFullName(tokenId);
        fullName = string.concat(fullName, ".wei");
        string memory displayName = bytes(fullName).length <= 20
            ? fullName
            : string.concat(_truncateUTF8(fullName, 17), "...");

        // Build attributes with expiry info for marketplace compatibility
        string memory attributes;
        if (record.parent == 0) {
            // Top-level name: show expiry
            attributes = string.concat(
                ',"attributes":[{"trait_type":"Expires","display_type":"date","value":',
                uint256(record.expiresAt).toString(),
                "}]"
            );
        } else {
            // Subdomain: no direct expiry
            attributes = ',"attributes":[{"trait_type":"Type","value":"Subdomain"}]';
        }

        string memory escapedName = _escapeJSON(fullName);

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"',
                        escapedName,
                        '","description":"Wei Name Service: ',
                        escapedName,
                        '","image":"data:image/svg+xml;base64,',
                        Base64.encode(bytes(_generateSVG(displayName))),
                        '"',
                        attributes,
                        "}"
                    )
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                            COMMIT-REVEAL
    //////////////////////////////////////////////////////////////*/

    function makeCommitment(string calldata label, address owner, bytes32 secret)
        public
        pure
        returns (bytes32)
    {
        bytes memory normalized = _validateAndNormalize(bytes(label));
        return keccak256(abi.encode(normalized, owner, secret));
    }

    function commit(bytes32 commitment) public {
        if (
            commitments[commitment] != 0
                && block.timestamp <= commitments[commitment] + MAX_COMMITMENT_AGE
        ) {
            revert AlreadyCommitted();
        }
        commitments[commitment] = block.timestamp;
        emit Committed(commitment, msg.sender);
    }

    function reveal(string calldata label, bytes32 secret)
        external
        payable
        nonReentrant
        returns (uint256 tokenId)
    {
        uint256 fee = getFee(bytes(label).length);
        bytes memory normalized = _validateAndNormalize(bytes(label));

        tokenId = uint256(keccak256(abi.encodePacked(WEI_NODE, keccak256(normalized))));
        uint256 premium = getPremium(tokenId);
        uint256 total = fee + premium;

        if (msg.value < total) revert InsufficientFee();

        bytes32 commitment = keccak256(abi.encode(normalized, msg.sender, secret));
        uint256 committedAt = commitments[commitment];

        if (committedAt == 0) revert CommitmentNotFound();
        if (block.timestamp < committedAt + MIN_COMMITMENT_AGE) revert CommitmentTooNew();
        if (block.timestamp > committedAt + MAX_COMMITMENT_AGE) revert CommitmentTooOld();

        delete commitments[commitment];
        _register(string(normalized), 0, msg.sender);

        if (msg.value > total) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - total);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          SUBDOMAIN REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function registerSubdomain(string calldata label, uint256 parentId)
        external
        nonReentrant
        returns (uint256)
    {
        if (!_isActive(parentId)) revert Expired();
        if (ownerOf(parentId) != msg.sender) revert NotParentOwner();
        return _register(label, parentId, msg.sender);
    }

    function registerSubdomainFor(string calldata label, uint256 parentId, address to)
        external
        nonReentrant
        returns (uint256)
    {
        if (!_isActive(parentId)) revert Expired();
        if (ownerOf(parentId) != msg.sender) revert NotParentOwner();
        return _register(label, parentId, to);
    }

    /*//////////////////////////////////////////////////////////////
                               RENEWAL
    //////////////////////////////////////////////////////////////*/

    function renew(uint256 tokenId) public payable nonReentrant {
        NameRecord storage record = records[tokenId];
        if (bytes(record.label).length == 0) revert TokenDoesNotExist();
        if (record.parent != 0) revert Unauthorized();
        if (block.timestamp > record.expiresAt + GRACE_PERIOD) revert Expired();

        uint256 fee = getFee(bytes(record.label).length);
        if (msg.value < fee) revert InsufficientFee();

        // Always extend from current expiry (ENS-style)
        // This is consistent whether renewing early or during grace
        record.expiresAt = record.expiresAt + uint64(REGISTRATION_PERIOD);

        emit NameRenewed(tokenId, record.expiresAt);

        if (msg.value > fee) {
            SafeTransferLib.safeTransferETH(msg.sender, msg.value - fee);
        }
    }

    function isExpired(uint256 tokenId) public view returns (bool) {
        uint64 exp = records[tokenId].expiresAt;
        return exp != 0 && block.timestamp > exp + GRACE_PERIOD;
    }

    function inGracePeriod(uint256 tokenId) public view returns (bool) {
        uint64 exp = records[tokenId].expiresAt;
        return exp != 0 && block.timestamp > exp && block.timestamp <= exp + GRACE_PERIOD;
    }

    function expiresAt(uint256 tokenId) public view returns (uint256) {
        return records[tokenId].expiresAt;
    }

    /*//////////////////////////////////////////////////////////////
                              RESOLUTION
    //////////////////////////////////////////////////////////////*/

    function setAddr(uint256 tokenId, address addr) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _resolvedAddress[tokenId][recordVersion[tokenId]] = addr;
        emit AddrChanged(bytes32(tokenId), addr);
    }

    function setPrimaryName(uint256 tokenId) public {
        if (tokenId != 0) {
            if (!_isActive(tokenId)) revert Expired();
            address resolved = resolve(tokenId);
            if (ownerOf(tokenId) != msg.sender && resolved != msg.sender) revert Unauthorized();
        }
        primaryName[msg.sender] = tokenId;
        emit PrimaryNameSet(msg.sender, tokenId);
    }

    function resolve(uint256 tokenId) public view returns (address) {
        if (!_isActive(tokenId)) return address(0);
        address addr = _resolvedAddress[tokenId][recordVersion[tokenId]];
        return addr != address(0) ? addr : ownerOf(tokenId);
    }

    function reverseResolve(address addr) public view returns (string memory) {
        uint256 tokenId = primaryName[addr];
        if (tokenId == 0 || !_isActive(tokenId) || resolve(tokenId) != addr) return "";
        return string.concat(_buildFullName(tokenId), ".wei");
    }

    /*//////////////////////////////////////////////////////////////
                         ENS-COMPATIBLE RESOLVER
    //////////////////////////////////////////////////////////////*/

    function setContenthash(uint256 tokenId, bytes calldata hash) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _contenthash[tokenId][recordVersion[tokenId]] = hash;
        emit ContenthashChanged(bytes32(tokenId), hash);
    }

    function contenthash(uint256 tokenId) public view returns (bytes memory) {
        if (!_isActive(tokenId)) return "";
        return _contenthash[tokenId][recordVersion[tokenId]];
    }

    function setAddrForCoin(uint256 tokenId, uint256 coinType, bytes calldata addr) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _coinAddr[tokenId][recordVersion[tokenId]][coinType] = addr;
        emit AddressChanged(bytes32(tokenId), coinType, addr);
    }

    function addr(uint256 tokenId, uint256 coinType) public view returns (bytes memory) {
        if (!_isActive(tokenId)) return "";
        uint256 v = recordVersion[tokenId];
        if (coinType == COIN_TYPE_ETH) {
            bytes memory a = _coinAddr[tokenId][v][COIN_TYPE_ETH];
            if (a.length > 0) return a;
            address resolved = resolve(tokenId);
            if (resolved != address(0)) return abi.encodePacked(resolved);
        }
        return _coinAddr[tokenId][v][coinType];
    }

    function setText(uint256 tokenId, string calldata key, string calldata value) public {
        if (!_isActive(tokenId)) revert Expired();
        if (ownerOf(tokenId) != msg.sender) revert Unauthorized();
        _text[tokenId][recordVersion[tokenId]][key] = value;
        emit TextChanged(bytes32(tokenId), key, value);
    }

    function text(uint256 tokenId, string calldata key) public view returns (string memory) {
        if (!_isActive(tokenId)) return "";
        return _text[tokenId][recordVersion[tokenId]][key];
    }

    // bytes32 overloads for ENS compatibility
    function addr(bytes32 node) public view returns (address) {
        return resolve(uint256(node));
    }

    function addr(bytes32 node, uint256 coinType) public view returns (bytes memory) {
        uint256 tokenId = uint256(node);
        if (!_isActive(tokenId)) return "";
        uint256 v = recordVersion[tokenId];
        if (coinType == COIN_TYPE_ETH) {
            bytes memory a = _coinAddr[tokenId][v][COIN_TYPE_ETH];
            if (a.length > 0) return a;
            address resolved = resolve(tokenId);
            if (resolved != address(0)) return abi.encodePacked(resolved);
        }
        return _coinAddr[tokenId][v][coinType];
    }

    function text(bytes32 node, string calldata key) public view returns (string memory) {
        uint256 tokenId = uint256(node);
        if (!_isActive(tokenId)) return "";
        return _text[tokenId][recordVersion[tokenId]][key];
    }

    function contenthash(bytes32 node) public view returns (bytes memory) {
        uint256 tokenId = uint256(node);
        if (!_isActive(tokenId)) return "";
        return _contenthash[tokenId][recordVersion[tokenId]];
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == 0x3b3b57de || interfaceId == 0xf1cb7e06 || interfaceId == 0x59d1d43c
            || interfaceId == 0xbc1c58d1 || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                               LOOKUPS
    //////////////////////////////////////////////////////////////*/

    function computeId(string calldata fullName) public pure returns (uint256) {
        return uint256(computeNamehash(fullName));
    }

    /// @notice Compute namehash for a full name (e.g. "sub.name.wei" or "name")
    /// @dev This function is intentionally permissive - it lowercases and hashes any input.
    ///      Registration enforces validation: valid UTF-8, no space/control chars/dot.
    ///      Use normalize() to check if a label is valid for registration.
    function computeNamehash(string calldata fullName) public pure returns (bytes32 node) {
        bytes memory b = bytes(fullName);
        if (b.length == 0) return WEI_NODE;

        uint256 len = b.length;

        // Strip .wei suffix if present
        if (
            len >= 4 && b[len - 4] == 0x2e && (b[len - 3] == 0x77 || b[len - 3] == 0x57)
                && (b[len - 2] == 0x65 || b[len - 2] == 0x45)
                && (b[len - 1] == 0x69 || b[len - 1] == 0x49)
        ) {
            len -= 4;
        }

        if (len == 0) return WEI_NODE;
        if (b[0] == 0x2e || b[len - 1] == 0x2e) revert EmptyLabel();

        node = WEI_NODE;
        uint256 labelEnd = len;

        for (uint256 i = len; i > 0; --i) {
            if (b[i - 1] == 0x2e) {
                if (i >= labelEnd) revert EmptyLabel();
                node = keccak256(abi.encodePacked(node, keccak256(_toLowerSlice(b, i, labelEnd))));
                labelEnd = i - 1;
            }
        }

        if (labelEnd > 0) {
            node = keccak256(abi.encodePacked(node, keccak256(_toLowerSlice(b, 0, labelEnd))));
        }
    }

    /// @notice Check if a label is available for registration
    /// @dev For subdomains, returns false if subdomain exists and is active, even though
    ///      the parent owner can overwrite it. Parent owners should use registerSubdomain()
    ///      directly - it will succeed for reclaim even when isAvailable() returns false.
    function isAvailable(string calldata label, uint256 parentId) public view returns (bool) {
        bytes memory b = bytes(label);
        if (b.length < MIN_LABEL_LENGTH || b.length > MAX_LABEL_LENGTH) return false;

        // UTF-8 validation and normalization (mirrors _validateAndNormalize but returns false instead of reverting)
        bytes memory normalized = new bytes(b.length);
        uint256 i;

        while (i < b.length) {
            uint8 cb = uint8(b[i]);

            // Reject control chars, space, dot, DEL
            if (cb <= 0x20 || cb == 0x7f || cb == 0x2e) return false;

            if (cb < 0x80) {
                // ASCII: lowercase A-Z
                normalized[i] = (cb >= 0x41 && cb <= 0x5a) ? bytes1(cb + 32) : b[i];
                i++;
            } else if (cb < 0xC2) {
                return false; // Invalid UTF-8 start byte
            } else if (cb < 0xE0) {
                if (i + 1 >= b.length) return false;
                uint8 b1 = uint8(b[i + 1]);
                if (b1 < 0x80 || b1 > 0xBF) return false;
                normalized[i] = b[i];
                normalized[i + 1] = b[i + 1];
                i += 2;
            } else if (cb < 0xF0) {
                if (i + 2 >= b.length) return false;
                uint8 b1 = uint8(b[i + 1]);
                uint8 b2 = uint8(b[i + 2]);
                if (b1 < 0x80 || b1 > 0xBF || b2 < 0x80 || b2 > 0xBF) return false;
                if (cb == 0xE0 && b1 < 0xA0) return false; // Overlong
                if (cb == 0xED && b1 >= 0xA0) return false; // Surrogate
                normalized[i] = b[i];
                normalized[i + 1] = b[i + 1];
                normalized[i + 2] = b[i + 2];
                i += 3;
            } else if (cb < 0xF5) {
                if (i + 3 >= b.length) return false;
                uint8 b1 = uint8(b[i + 1]);
                uint8 b2 = uint8(b[i + 2]);
                uint8 b3 = uint8(b[i + 3]);
                if (b1 < 0x80 || b1 > 0xBF || b2 < 0x80 || b2 > 0xBF || b3 < 0x80 || b3 > 0xBF) {
                    return false;
                }
                if (cb == 0xF0 && b1 < 0x90) return false; // Overlong
                if (cb == 0xF4 && b1 > 0x8F) return false; // Above U+10FFFF
                normalized[i] = b[i];
                normalized[i + 1] = b[i + 1];
                normalized[i + 2] = b[i + 2];
                normalized[i + 3] = b[i + 3];
                i += 4;
            } else {
                return false; // Invalid UTF-8
            }
        }

        // Hyphen rules
        if (normalized[0] == 0x2d || normalized[b.length - 1] == 0x2d) return false;

        bytes32 parentNode = parentId == 0 ? WEI_NODE : bytes32(parentId);
        uint256 tokenId = uint256(keccak256(abi.encodePacked(parentNode, keccak256(normalized))));

        if (parentId != 0 && !_isActive(parentId)) return false;
        if (parentId != 0 && _getDepth(parentId) >= MAX_SUBDOMAIN_DEPTH) return false;
        if (!_recordExists(tokenId)) return true;

        NameRecord storage record = records[tokenId];
        if (record.parent == 0) return isExpired(tokenId);

        if (parentId != 0) {
            return record.parentEpoch != records[parentId].epoch;
        }
        return false;
    }

    function getFullName(uint256 tokenId) public view returns (string memory) {
        string memory baseName = _buildFullName(tokenId);
        if (bytes(baseName).length == 0) return "";
        return string.concat(baseName, ".wei");
    }

    /// @notice On-chain normalization (lowercases ASCII only)
    /// @dev For full Unicode normalization, use ENSIP-15 library off-chain
    function normalize(string calldata label) public pure returns (string memory) {
        return string(_validateAndNormalize(bytes(label)));
    }

    /// @notice Check if label contains only ASCII characters
    /// @dev If true, on-chain normalize() is sufficient. If false, use ENSIP-15 off-chain.
    function isAsciiLabel(string calldata label) public pure returns (bool) {
        bytes memory b = bytes(label);
        for (uint256 i; i < b.length; ++i) {
            if (uint8(b[i]) > 127) return false;
        }
        return true;
    }

    /*//////////////////////////////////////////////////////////////
                            FEE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function getFee(uint256 length) public view returns (uint256) {
        return lengthFeeSet[length] ? lengthFees[length] : defaultFee;
    }

    function getPremium(uint256 tokenId) public view returns (uint256) {
        NameRecord storage record = records[tokenId];
        if (bytes(record.label).length == 0 || record.parent != 0) return 0;
        if (maxPremium == 0 || premiumDecayPeriod == 0) return 0;

        uint256 gracePeriodEnd = record.expiresAt + GRACE_PERIOD;
        if (block.timestamp <= gracePeriodEnd) return 0;

        uint256 elapsed = block.timestamp - gracePeriodEnd;
        if (elapsed >= premiumDecayPeriod) return 0;

        return maxPremium * (premiumDecayPeriod - elapsed) / premiumDecayPeriod;
    }

    /*//////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setDefaultFee(uint256 fee) public onlyOwner {
        defaultFee = fee;
        emit DefaultFeeChanged(fee);
    }

    function setLengthFees(uint256[] calldata lengths, uint256[] calldata fees) public onlyOwner {
        if (lengths.length != fees.length) revert LengthMismatch();
        for (uint256 i; i < lengths.length; ++i) {
            lengthFees[lengths[i]] = fees[i];
            lengthFeeSet[lengths[i]] = true;
            emit LengthFeeChanged(lengths[i], fees[i]);
        }
    }

    function clearLengthFee(uint256 length) public onlyOwner {
        delete lengthFees[length];
        delete lengthFeeSet[length];
        emit LengthFeeCleared(length);
    }

    function setPremiumSettings(uint256 _maxPremium, uint256 _decayPeriod) public onlyOwner {
        if (_maxPremium > MAX_PREMIUM_CAP) revert PremiumTooHigh();
        if (_decayPeriod > MAX_DECAY_PERIOD) revert DecayPeriodTooLong();
        maxPremium = _maxPremium;
        premiumDecayPeriod = _decayPeriod;
        emit PremiumSettingsChanged(_maxPremium, _decayPeriod);
    }

    function withdraw() public onlyOwner nonReentrant {
        SafeTransferLib.safeTransferAllETH(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _register(string memory label, uint256 parentId, address to)
        internal
        returns (uint256 tokenId)
    {
        bytes memory normalized = _validateAndNormalize(bytes(label));
        bytes32 parentNode = parentId == 0 ? WEI_NODE : bytes32(parentId);
        tokenId = uint256(keccak256(abi.encodePacked(parentNode, keccak256(normalized))));

        // Invariant: subdomain registration requires parent ownership
        if (parentId != 0) {
            if (ownerOf(parentId) != msg.sender) revert NotParentOwner();
            if (_getDepth(parentId) >= MAX_SUBDOMAIN_DEPTH) revert TooDeep();
        }

        NameRecord storage existing = records[tokenId];
        uint64 newEpoch = 1;

        if (bytes(existing.label).length > 0) {
            if (parentId == 0) {
                // Top-level: must be expired past grace
                if (block.timestamp <= existing.expiresAt + GRACE_PERIOD) {
                    revert AlreadyRegistered();
                }
            }
            // Subdomain overwrites: parent owner can always reclaim (checked above)
            // Stale subdomains can also be overwritten by new parent owner

            newEpoch = existing.epoch + 1;
            address oldOwner = ownerOf(tokenId); // Safe: _burn allows burning inactive tokens
            _burn(tokenId);
            if (primaryName[oldOwner] == tokenId) delete primaryName[oldOwner];
            recordVersion[tokenId]++;
        }

        records[tokenId] = NameRecord({
            label: string(normalized),
            parent: parentId,
            expiresAt: parentId == 0 ? uint64(block.timestamp + REGISTRATION_PERIOD) : 0,
            epoch: newEpoch,
            parentEpoch: parentId == 0 ? 0 : records[parentId].epoch
        });

        _safeMint(to, tokenId);

        emit NameRegistered(tokenId, string(normalized), to, records[tokenId].expiresAt);
        if (parentId != 0) emit SubdomainRegistered(tokenId, parentId, string(normalized));
    }

    /// @notice Validates UTF-8 encoding and lowercases ASCII. Unicode normalization should be done off-chain.
    /// @dev Validates UTF-8 structure (rejects invalid sequences, overlong encodings, surrogates).
    ///      Only ASCII A-Z is lowercased. For full Unicode normalization, use ENSIP-15 off-chain.
    function _validateAndNormalize(bytes memory b) internal pure returns (bytes memory) {
        if (b.length < MIN_LABEL_LENGTH || b.length > MAX_LABEL_LENGTH) revert InvalidLength();

        bytes memory result = new bytes(b.length);
        uint256 i;

        while (i < b.length) {
            uint8 cb = uint8(b[i]);

            // Reject control characters (0x00-0x1F), space (0x20), dot (0x2E), and DEL (0x7F)
            if (cb <= 0x20 || cb == 0x7f || cb == 0x2e) revert InvalidName();

            if (cb < 0x80) {
                // ASCII: lowercase A-Z
                if (cb >= 0x41 && cb <= 0x5a) {
                    result[i] = bytes1(cb + 32);
                } else {
                    result[i] = b[i];
                }
                i++;
            } else if (cb < 0xC2) {
                // 0x80-0xC1: invalid (continuation bytes or overlong)
                revert InvalidName();
            } else if (cb < 0xE0) {
                // 2-byte sequence: 0xC2-0xDF followed by 1 continuation byte
                if (i + 1 >= b.length) revert InvalidName();
                if (uint8(b[i + 1]) < 0x80 || uint8(b[i + 1]) > 0xBF) revert InvalidName();
                result[i] = b[i];
                result[i + 1] = b[i + 1];
                i += 2;
            } else if (cb < 0xF0) {
                // 3-byte sequence: 0xE0-0xEF followed by 2 continuation bytes
                if (i + 2 >= b.length) revert InvalidName();
                uint8 b1 = uint8(b[i + 1]);
                uint8 b2 = uint8(b[i + 2]);
                // Check continuation bytes are valid
                if (b1 < 0x80 || b1 > 0xBF || b2 < 0x80 || b2 > 0xBF) revert InvalidName();
                // Reject overlong (0xE0 must be followed by 0xA0-0xBF)
                if (cb == 0xE0 && b1 < 0xA0) revert InvalidName();
                // Reject surrogates (0xED followed by 0xA0-0xBF = U+D800-U+DFFF)
                if (cb == 0xED && b1 >= 0xA0) revert InvalidName();
                result[i] = b[i];
                result[i + 1] = b[i + 1];
                result[i + 2] = b[i + 2];
                i += 3;
            } else if (cb < 0xF5) {
                // 4-byte sequence: 0xF0-0xF4 followed by 3 continuation bytes
                if (i + 3 >= b.length) revert InvalidName();
                uint8 b1 = uint8(b[i + 1]);
                uint8 b2 = uint8(b[i + 2]);
                uint8 b3 = uint8(b[i + 3]);
                // Check continuation bytes are valid
                if (b1 < 0x80 || b1 > 0xBF || b2 < 0x80 || b2 > 0xBF || b3 < 0x80 || b3 > 0xBF) {
                    revert InvalidName();
                }
                // Reject overlong (0xF0 must be followed by 0x90-0xBF)
                if (cb == 0xF0 && b1 < 0x90) revert InvalidName();
                // Reject above U+10FFFF (0xF4 must be followed by 0x80-0x8F)
                if (cb == 0xF4 && b1 > 0x8F) revert InvalidName();
                result[i] = b[i];
                result[i + 1] = b[i + 1];
                result[i + 2] = b[i + 2];
                result[i + 3] = b[i + 3];
                i += 4;
            } else {
                // 0xF5-0xFF: invalid
                revert InvalidName();
            }
        }

        // Hyphen rules: can't start or end with hyphen
        if (result[0] == 0x2d || result[b.length - 1] == 0x2d) revert InvalidName();

        return result;
    }

    function _toLowerSlice(bytes memory b, uint256 start, uint256 end)
        internal
        pure
        returns (bytes memory)
    {
        unchecked {
            uint256 len = end - start;
            bytes memory result = new bytes(len);
            for (uint256 i; i < len; ++i) {
                bytes1 c = b[start + i];
                result[i] = (c >= 0x41 && c <= 0x5a) ? bytes1(uint8(c) + 32) : c;
            }
            return result;
        }
    }

    /// @dev Truncate string to maxBytes, ensuring we don't cut in the middle of a UTF-8 character
    function _truncateUTF8(string memory str, uint256 maxBytes)
        internal
        pure
        returns (string memory)
    {
        bytes memory b = bytes(str);
        if (b.length <= maxBytes) return str;

        // Find safe cut point - step back over UTF-8 continuation bytes (0x80-0xBF)
        // This ensures we don't cut in the middle of a multi-byte character
        uint256 cutPoint = maxBytes;
        while (cutPoint > 0 && uint8(b[cutPoint]) >= 0x80 && uint8(b[cutPoint]) <= 0xBF) {
            unchecked {
                --cutPoint;
            }
        }
        // cutPoint is now at either:
        // - An ASCII byte (will be included as it's a complete character)
        // - A multi-byte start byte (won't be included since we copy 0..cutPoint-1)

        bytes memory result = new bytes(cutPoint);
        for (uint256 i; i < cutPoint; ++i) {
            result[i] = b[i];
        }
        return string(result);
    }

    function _recordExists(uint256 tokenId) internal view returns (bool) {
        return bytes(records[tokenId].label).length > 0;
    }

    function _getDepth(uint256 tokenId) internal view returns (uint256 depth) {
        uint256 current = tokenId;
        while (current != 0) {
            uint256 parent = records[current].parent;
            if (parent == 0) break;
            depth++;
            if (depth > MAX_SUBDOMAIN_DEPTH) return depth;
            current = parent;
        }
    }

    function _isActive(uint256 tokenId) internal view returns (bool) {
        return _isActiveWithDepth(tokenId, 0);
    }

    function _isActiveWithDepth(uint256 tokenId, uint256 depth) internal view returns (bool) {
        if (depth > MAX_SUBDOMAIN_DEPTH) return false;
        NameRecord storage record = records[tokenId];
        if (bytes(record.label).length == 0) return false;

        if (record.parent != 0) {
            if (record.parentEpoch != records[record.parent].epoch) return false;
            return _isActiveWithDepth(record.parent, depth + 1);
        }
        // ENS-like: active only until expiresAt (not through grace)
        // Grace period is for renewal only, not transfers/resolver writes
        return block.timestamp <= record.expiresAt;
    }

    function _buildFullName(uint256 tokenId) internal view returns (string memory) {
        return _buildFullNameWithDepth(tokenId, 0);
    }

    function _buildFullNameWithDepth(uint256 tokenId, uint256 depth)
        internal
        view
        returns (string memory)
    {
        if (tokenId == 0 || depth > MAX_SUBDOMAIN_DEPTH) return "";
        NameRecord storage record = records[tokenId];
        if (bytes(record.label).length == 0) return "";

        if (record.parent != 0 && record.parentEpoch != records[record.parent].epoch) return "";
        if (record.parent == 0) return record.label;

        string memory parentName = _buildFullNameWithDepth(record.parent, depth + 1);
        if (bytes(parentName).length == 0) return "";
        return string.concat(record.label, ".", parentName);
    }

    function _generateSVG(string memory displayName) internal pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400"><rect width="400" height="400" fill="#fff"/><text x="200" y="200" font-family="sans-serif" font-size="24" text-anchor="middle" dominant-baseline="middle">',
            _escapeXML(displayName),
            "</text></svg>"
        );
    }

    /// @dev Escape JSON special characters for safe metadata embedding
    function _escapeJSON(string memory input) internal pure returns (string memory) {
        bytes memory b = bytes(input);

        // First pass: count output length
        uint256 outLen;
        unchecked {
            for (uint256 i; i < b.length; ++i) {
                bytes1 c = b[i];
                if (c == 0x22 || c == 0x5c) {
                    outLen += 2;
                } else if (c == 0x0a || c == 0x0d || c == 0x09) {
                    outLen += 2;
                } else if (uint8(c) >= 0x20) {
                    outLen += 1;
                }
            }
        }

        if (outLen == b.length) return input;

        bytes memory result = new bytes(outLen);
        uint256 j;

        unchecked {
            for (uint256 i; i < b.length; ++i) {
                bytes1 c = b[i];
                if (c == 0x22) {
                    result[j++] = "\\";
                    result[j++] = '"';
                } else if (c == 0x5c) {
                    result[j++] = "\\";
                    result[j++] = "\\";
                } else if (c == 0x0a) {
                    result[j++] = "\\";
                    result[j++] = "n";
                } else if (c == 0x0d) {
                    result[j++] = "\\";
                    result[j++] = "r";
                } else if (c == 0x09) {
                    result[j++] = "\\";
                    result[j++] = "t";
                } else if (uint8(c) >= 0x20) {
                    result[j++] = c;
                }
            }
        }

        return string(result);
    }

    /// @dev Escape XML special characters for safe SVG embedding
    function _escapeXML(string memory input) internal pure returns (string memory) {
        bytes memory b = bytes(input);

        // Count how much extra space we need
        uint256 extraLen;
        unchecked {
            for (uint256 i; i < b.length; ++i) {
                bytes1 c = b[i];
                if (c == 0x26) extraLen += 4;
                else if (c == 0x3c) extraLen += 3;
                else if (c == 0x3e) extraLen += 3;
                else if (c == 0x22) extraLen += 5;
                else if (c == 0x27) extraLen += 5;
            }
        }

        if (extraLen == 0) return input;

        bytes memory result = new bytes(b.length + extraLen);
        uint256 j;

        unchecked {
            for (uint256 i; i < b.length; ++i) {
                bytes1 c = b[i];
                if (c == 0x26) {
                    result[j++] = "&";
                    result[j++] = "a";
                    result[j++] = "m";
                    result[j++] = "p";
                    result[j++] = ";";
                } else if (c == 0x3c) {
                    result[j++] = "&";
                    result[j++] = "l";
                    result[j++] = "t";
                    result[j++] = ";";
                } else if (c == 0x3e) {
                    result[j++] = "&";
                    result[j++] = "g";
                    result[j++] = "t";
                    result[j++] = ";";
                } else if (c == 0x22) {
                    result[j++] = "&";
                    result[j++] = "q";
                    result[j++] = "u";
                    result[j++] = "o";
                    result[j++] = "t";
                    result[j++] = ";";
                } else if (c == 0x27) {
                    result[j++] = "&";
                    result[j++] = "a";
                    result[j++] = "p";
                    result[j++] = "o";
                    result[j++] = "s";
                    result[j++] = ";";
                } else {
                    result[j++] = c;
                }
            }
        }

        return string(result);
    }
}
