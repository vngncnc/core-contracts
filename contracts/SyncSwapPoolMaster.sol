// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.0;

import "./interfaces/pool/IPool.sol";
import "./interfaces/IPoolMaster.sol";
import "./interfaces/factory/IPoolFactory.sol";

import "./libraries/Ownable.sol";

error NotWhitelistedFactory();
error InvalidFee();
error PoolAlreadyExists();

/// @notice The pool master manages swap fees for pools, whitelist for factories,
/// protocol fee and pool registry.
///
/// It accepts pool registers from whitelisted factories, with the pool data on pool
/// creation, to enable querying of the existence or fees of a pool by address or config.
///
/// This contract provides a unified interface to query and manage fees across
/// different pool types, and a unique registry for all pools.
///
contract SyncSwapPoolMaster is IPoolMaster, Ownable {
    uint24 private constant MAX_FEE = 1e5; /// @dev 100%.
    uint24 private constant MAX_SWAP_FEE = 10000; /// @dev 10%.
    uint24 private constant ZERO_CUSTOM_SWAP_FEE = type(uint24).max;

    /// @dev The vault that holds funds.
    address public immutable override vault;

    // Fees

    /// @dev The default swap fee by pool type.
    mapping(uint16 => uint24) public override defaultSwapFee; /// @dev `300` for 0.3%.

    /// @dev The custom swap fee by pool address, use `ZERO_CUSTOM_SWAP_FEE` for zero fee.
    mapping(address => uint24) public override customSwapFee;

    /// @dev The recipient of protocol fees.
    address public override feeRecipient;

    /// @dev The protocol fee of swap fee by pool type.
    mapping(uint16 => uint24) public override protocolFee; /// @dev `30000` for 30%.

    // Factories

    /// @dev Whether an address is a factory.
    mapping(address => bool) public override isFactoryWhitelisted;

    // Pools

    /// @dev Whether an address is a pool.
    mapping(address => bool) public override isPool;

    /// @dev Pools by hash of its config.
    mapping(bytes32 => address) public getPool;

    constructor(address _vault, address _feeRecipient) {
        vault = _vault;
        feeRecipient = _feeRecipient;

        // Prefill fees for known pool types.
        // Classic pools.
        defaultSwapFee[1] = 300; // 0.3%.
        protocolFee[1] = 30000; // 30%.

        // Stable pools.
        defaultSwapFee[2] = 100; // 0.1%.
        protocolFee[2] = 50000; // 50%.
    }

    // Fees

    function getSwapFee(address pool) external view override returns (uint24 swapFee) {
        uint24 _customSwapFee = customSwapFee[pool];

        if (_customSwapFee == 0) {
            swapFee = defaultSwapFee[IPool(pool).poolType()]; // use default instead if not set.
        } else {
            swapFee = (_customSwapFee == ZERO_CUSTOM_SWAP_FEE ? 0 : _customSwapFee);
        }
    }

    function setDefaultSwapFee(uint16 poolType, uint24 _defaultSwapFee) external onlyOwner {
        if (_defaultSwapFee > MAX_SWAP_FEE) {
            revert InvalidFee();
        }
        defaultSwapFee[poolType] = _defaultSwapFee;
        emit SetDefaultSwapFee(poolType, _defaultSwapFee);
    }

    function setCustomSwapFee(address pool, uint24 _customSwapFee) external onlyOwner {
        if (_customSwapFee > MAX_SWAP_FEE && _customSwapFee != ZERO_CUSTOM_SWAP_FEE) {
            revert InvalidFee();
        }
        customSwapFee[pool] = _customSwapFee;
        emit SetCustomSwapFee(pool, _customSwapFee);
    }

    function setProtocolFee(uint16 poolType, uint24 _protocolFee) external onlyOwner {
        if (_protocolFee > MAX_FEE) {
            revert InvalidFee();
        }
        protocolFee[poolType] = _protocolFee;
        emit SetProtocolFee(poolType, _protocolFee);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        // Emit here to avoid caching the previous recipient.
        emit SetFeeRecipient(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    // Factories

    function setFactoryWhitelisted(address factory, bool whitelisted) external onlyOwner {
        isFactoryWhitelisted[factory] = whitelisted;
        emit SetFactoryWhitelisted(factory, whitelisted);
    }

    // Pools

    /// @dev Create a pool with deployment data and, register it via the factory.
    function createPool(address factory, bytes calldata data) external override returns (address pool) {
        // The factory have to call `registerPool` to register the pool.
        // The pool whitelist is checked in `registerPool`.
        pool = IPoolFactory(factory).createPool(data);
    }

    /// @dev Register a pool to the mapping by its config. Can only be called by factories.
    function registerPool(address pool, uint16 poolType, bytes calldata data) external override {
        if (!isFactoryWhitelisted[msg.sender]) {
            revert NotWhitelistedFactory();
        }

        require(pool != address(0));

        // Double check to prevent duplicated pools.
        if (isPool[pool]) {
            revert PoolAlreadyExists();
        }

        // Encode and hash pool config to get the mapping key.
        bytes32 hash = keccak256(abi.encode(poolType, data));

        // Double check to prevent duplicated pools.
        if (getPool[hash] != address(0)) {
            revert PoolAlreadyExists();
        }

        // Set to mappings.
        getPool[hash] = pool;
        isPool[pool] = true;

        emit RegisterPool(msg.sender, pool, poolType, data);
    }
}