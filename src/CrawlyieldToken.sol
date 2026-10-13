// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title Crawlyield (CRAWL)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 CRAWL (18 decimals) is minted
///         once, in the constructor, to the deployer (`msg.sender`). Nothing can mint afterwards.
/// @dev Deliberately minimal:
///      - no owner, admin, minter or upgrade path: the contract has no privileged role at all;
///      - no fee, tax, reflection or burn on transfer: every transfer moves exactly the amount given;
///      - no pause, blacklist, freeze or seize: nobody but a holder (or a spender the holder
///        approved) can move or lock a holder's balance;
///      - holders may burn their own tokens (`burn`) or tokens they were approved to spend
///        (`burnFrom`), so total supply can only ever shrink;
///      - EIP-2612 `permit` for gasless approvals.
///      The deployer is whoever runs the constructor. On an IdentityMD launch that is the
///      ProjectFactory, which then pays the supply out (swarm share, pool seed, remainder).
contract CrawlyieldToken is ERC20, ERC20Burnable, ERC20Permit {
    /// @notice Token name returned by `name()`.
    string public constant TOKEN_NAME = "Crawlyield";

    /// @notice Token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "CRAWL";

    /// @notice Number of decimals; `decimals()` returns this.
    uint8 public constant DECIMALS = 18;

    /// @notice The entire supply, in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice Mints `TOTAL_SUPPLY` to the deployer. Takes no arguments and makes no external calls.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) ERC20Permit(TOKEN_NAME) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @inheritdoc ERC20
    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }
}
