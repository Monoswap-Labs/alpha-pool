// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import './interfaces/IAlphaPool.sol';
import './libraries/IncentiveId.sol';
import './libraries/RewardMath.sol';
import './libraries/NFTPositionInfo.sol';
import './libraries/TransferHelperExtended.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol';
import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';
import '@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol';

import '@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@uniswap/v3-periphery/contracts/base/Multicall.sol';

import '@openzeppelin/contracts/utils/EnumerableSet.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';

import '@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol';

/// @title Uniswap V3 canonical staking interface
contract AlphaPool is IAlphaPool, Multicall, AccessControl{
    using EnumerableSet for EnumerableSet.UintSet;
    /// @notice Represents a staking incentive
    struct Incentive {
        uint256 totalRewardUnclaimed;
        uint160 totalSecondsClaimedX128;
        uint96 numberOfStakes;
    }

    struct IncentiveKeyRes {
        IERC20Minimal rewardToken;
        IUniswapV3Pool pool;
        uint256 startTime;
        uint256 endTime;
        address refundee;
        address token0;
        address token1;
        uint256 totalRewardUnclaimed;
        uint160 totalSecondsClaimedX128;
        uint96 numberOfStakes;
    }

    /// @notice Represents the deposit of a liquidity NFT
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Represents a staked liquidity NFT
    struct Stake {
        uint160 secondsPerLiquidityInsideInitialX128;
        uint96 liquidityNoOverflow;
        uint128 liquidityIfOverflow;
    }

    /// @inheritdoc IAlphaPool
    IUniswapV3Factory public immutable override factory;
    /// @inheritdoc IAlphaPool
    INonfungiblePositionManager public immutable override nonfungiblePositionManager;

    /// @inheritdoc IAlphaPool
    uint256 public immutable override maxIncentiveStartLeadTime;
    /// @inheritdoc IAlphaPool
    uint256 public immutable override maxIncentiveDuration;

    /// @dev bytes32 refers to the return value of IncentiveId.compute
    mapping(bytes32 => Incentive) public override incentives;
    mapping(bytes32 => IncentiveKey) public incentiveKeys;
    bytes32[] public incentiveIds;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public override deposits;
    mapping(address => EnumerableSet.UintSet) private _tokenIdsByOwner;

    /// @dev stakes[tokenId][incentiveHash] => Stake
    mapping(uint256 => mapping(bytes32 => Stake)) private _stakes;

    modifier onlyRole(bytes32 role) {
        require(hasRole(role, msg.sender), 'AlphaPool::onlyRole: UNAUTHORIZED');
        _;
    }

    /// @inheritdoc IAlphaPool
    function stakes(uint256 tokenId, bytes32 incentiveId)
        public
        view
        override
        returns (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity)
    {
        Stake storage stake = _stakes[tokenId][incentiveId];
        secondsPerLiquidityInsideInitialX128 = stake.secondsPerLiquidityInsideInitialX128;
        liquidity = stake.liquidityNoOverflow;
        if (liquidity == type(uint96).max) {
            liquidity = stake.liquidityIfOverflow;
        }
    }

    /// @dev rewards[rewardToken][owner] => uint256
    /// @inheritdoc IAlphaPool
    mapping(IERC20Minimal => mapping(address => uint256)) public override rewards;

    /// @param _factory the Uniswap V3 factory
    /// @param _nonfungiblePositionManager the NFT position manager contract address
    /// @param _maxIncentiveStartLeadTime the max duration of an incentive in seconds
    /// @param _maxIncentiveDuration the max amount of seconds into the future the incentive startTime can be set
    constructor(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentiveDuration
    ) {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        maxIncentiveStartLeadTime = _maxIncentiveStartLeadTime;
        maxIncentiveDuration = _maxIncentiveDuration;
    }

    /// @inheritdoc IAlphaPool
    function createIncentive(IncentiveKey memory key, uint256 reward) external override {
        require(reward > 0, 'AlphaPool::createIncentive: reward must be positive');
        require(
            block.timestamp <= key.startTime,
            'AlphaPool::createIncentive: start time must be now or in the future'
        );
        require(
            key.startTime - block.timestamp <= maxIncentiveStartLeadTime,
            'AlphaPool::createIncentive: start time too far into future'
        );
        require(key.startTime < key.endTime, 'AlphaPool::createIncentive: start time must be before end time');
        require(
            key.endTime - key.startTime <= maxIncentiveDuration,
            'AlphaPool::createIncentive: incentive duration is too long'
        );
        IUniswapV3Pool(key.pool).slot0(); // ensure pool exists
        bytes32 incentiveId = IncentiveId.compute(key);
        incentiveKeys[incentiveId] = key;

        incentives[incentiveId].totalRewardUnclaimed += reward;

        TransferHelperExtended.safeTransferFrom(address(key.rewardToken), msg.sender, address(this), reward);
        incentiveIds.push(incentiveId);
        emit IncentiveCreated(key.rewardToken, key.pool, key.startTime, key.endTime, key.refundee, reward);
    }

    /// @inheritdoc IAlphaPool
    function endIncentive(IncentiveKey memory key) external override returns (uint256 refund) {
        require(block.timestamp >= key.endTime, 'AlphaPool::endIncentive: cannot end incentive before end time');

        bytes32 incentiveId = IncentiveId.compute(key);
        Incentive storage incentive = incentives[incentiveId];

        refund = incentive.totalRewardUnclaimed;

        require(refund > 0, 'AlphaPool::endIncentive: no refund available');
        require(
            incentive.numberOfStakes == 0,
            'AlphaPool::endIncentive: cannot end incentive while deposits are staked'
        );

        // issue the refund
        incentive.totalRewardUnclaimed = 0;
        TransferHelperExtended.safeTransfer(address(key.rewardToken), key.refundee, refund);

        // note we never clear totalSecondsClaimedX128

        emit IncentiveEnded(incentiveId, refund);
    }

    /// @notice Upon receiving a Uniswap V3 ERC721, creates the token deposit setting owner to `from`. Also stakes token
    /// in one or more incentives if properly formatted `data` has a length > 0.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(
            msg.sender == address(nonfungiblePositionManager),
            'AlphaPool::onERC721Received: not a univ3 nft'
        );

        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = nonfungiblePositionManager.positions(tokenId);

        deposits[tokenId] = Deposit({owner: from, numberOfStakes: 0, tickLower: tickLower, tickUpper: tickUpper});
        _tokenIdsByOwner[from].add(tokenId);
        emit DepositTransferred(tokenId, address(0), from);

        if (data.length > 0) {
            if (data.length == 160) {
                _stakeToken(abi.decode(data, (IncentiveKey)), tokenId);
            } else {
                IncentiveKey[] memory keys = abi.decode(data, (IncentiveKey[]));
                for (uint256 i = 0; i < keys.length; i++) {
                    _stakeToken(keys[i], tokenId);
                }
            }
        }
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IAlphaPool
    function transferDeposit(uint256 tokenId, address to) external override {
        require(to != address(0), 'AlphaPool::transferDeposit: invalid transfer recipient');
        address owner = deposits[tokenId].owner;
        _tokenIdsByOwner[owner].remove(tokenId);
        require(owner == msg.sender, 'AlphaPool::transferDeposit: can only be called by deposit owner');
        deposits[tokenId].owner = to;
        _tokenIdsByOwner[to].add(tokenId);
        emit DepositTransferred(tokenId, owner, to);
    }

    /// @inheritdoc IAlphaPool
    function withdrawToken(
        uint256 tokenId,
        address to,
        bytes memory data
    ) public override {
        require(to != address(this), 'AlphaPool::withdrawToken: cannot withdraw to staker');
        Deposit memory deposit = deposits[tokenId];
        require(deposit.numberOfStakes == 0, 'AlphaPool::withdrawToken: cannot withdraw token while staked');
        require(deposit.owner == msg.sender, 'AlphaPool::withdrawToken: only owner can withdraw token');

        delete deposits[tokenId];
        _tokenIdsByOwner[msg.sender].remove(tokenId);
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    function depositAndStake(
        IncentiveKey memory key,
        uint256 tokenId
    ) external {
        nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId);
        stakeToken(key, tokenId);
    }

    /// @inheritdoc IAlphaPool
    function stakeToken(IncentiveKey memory key, uint256 tokenId) public override {
        require(deposits[tokenId].owner == msg.sender, 'AlphaPool::stakeToken: only owner can stake token');

        _stakeToken(key, tokenId);
    }

    /// @inheritdoc IAlphaPool
    function unstakeToken(IncentiveKey memory key, uint256 tokenId) public override {
        Deposit memory deposit = deposits[tokenId];
        // anyone can call unstakeToken if the block time is after the end time of the incentive
        if (block.timestamp < key.endTime) {
            require(
                deposit.owner == msg.sender,
                'AlphaPool::unstakeToken: only owner can withdraw token before incentive end time'
            );
        }

        bytes32 incentiveId = IncentiveId.compute(key);

        (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity) = stakes(tokenId, incentiveId);

        require(liquidity != 0, 'AlphaPool::unstakeToken: stake does not exist');

        Incentive storage incentive = incentives[incentiveId];

        deposits[tokenId].numberOfStakes--;
        incentive.numberOfStakes--;

        (, uint160 secondsPerLiquidityInsideX128, ) =
            key.pool.snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);
        (uint256 reward, uint160 secondsInsideX128) =
            RewardMath.computeRewardAmount(
                incentive.totalRewardUnclaimed,
                incentive.totalSecondsClaimedX128,
                key.startTime,
                key.endTime,
                liquidity,
                secondsPerLiquidityInsideInitialX128,
                secondsPerLiquidityInsideX128,
                block.timestamp
            );

        // if this overflows, e.g. after 2^32-1 full liquidity seconds have been claimed,
        // reward rate will fall drastically so it's safe
        incentive.totalSecondsClaimedX128 += secondsInsideX128;
        // reward is never greater than total reward unclaimed
        incentive.totalRewardUnclaimed -= reward;
        // this only overflows if a token has a total supply greater than type(uint256).max
        rewards[key.rewardToken][deposit.owner] += reward;

        Stake storage stake = _stakes[tokenId][incentiveId];
        delete stake.secondsPerLiquidityInsideInitialX128;
        delete stake.liquidityNoOverflow;
        if (liquidity >= type(uint96).max) delete stake.liquidityIfOverflow;
        emit TokenUnstaked(tokenId, incentiveId);
    }

    function unstakeAndWithdraw(
        IncentiveKey memory key,
        uint256 tokenId,
        address to
    ) external {
        unstakeToken(key, tokenId);
        withdrawToken(tokenId, to, new bytes(0));
    }

    /// @inheritdoc IAlphaPool
    function claimReward(
        IERC20Minimal rewardToken,
        address to,
        uint256 amountRequested
    ) external override returns (uint256 reward) {
        reward = rewards[rewardToken][msg.sender];
        if (amountRequested != 0 && amountRequested < reward) {
            reward = amountRequested;
        }

        rewards[rewardToken][msg.sender] -= reward;
        if (reward == 0) {
            return 0;
        }
        TransferHelperExtended.safeTransfer(address(rewardToken), to, reward);

        emit RewardClaimed(to, reward);
    }

    /// @inheritdoc IAlphaPool
    function getRewardInfo(IncentiveKey memory key, uint256 tokenId)
        external
        view
        override
        returns (uint256 reward, uint160 secondsInsideX128)
    {
        bytes32 incentiveId = IncentiveId.compute(key);

        (uint160 secondsPerLiquidityInsideInitialX128, uint128 liquidity) = stakes(tokenId, incentiveId);
        require(liquidity > 0, 'AlphaPool::getRewardInfo: stake does not exist');

        Deposit memory deposit = deposits[tokenId];
        Incentive memory incentive = incentives[incentiveId];

        (, uint160 secondsPerLiquidityInsideX128, ) =
            key.pool.snapshotCumulativesInside(deposit.tickLower, deposit.tickUpper);

        (reward, secondsInsideX128) = RewardMath.computeRewardAmount(
            incentive.totalRewardUnclaimed,
            incentive.totalSecondsClaimedX128,
            key.startTime,
            key.endTime,
            liquidity,
            secondsPerLiquidityInsideInitialX128,
            secondsPerLiquidityInsideX128,
            block.timestamp
        );
    }

    function getIncentiveId(IncentiveKey memory key) external pure  returns (bytes32) {
        return IncentiveId.compute(key);
    }

    function getIncentive(IncentiveKey memory key) external view  returns (Incentive memory) {
        return incentives[IncentiveId.compute(key)];
    }

    function getIncentiveIds() external view returns (bytes32[] memory) {
        return incentiveIds;
    }

    function getIncentiveKeys(uint256 offset, uint256 limit) external view  returns (IncentiveKeyRes[] memory result) {
        uint256 end = offset + limit;
        if (end > incentiveIds.length) {
            end = incentiveIds.length;
        }
        result = new IncentiveKeyRes[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = IncentiveKeyRes({
                rewardToken: incentiveKeys[incentiveIds[i]].rewardToken,
                pool: incentiveKeys[incentiveIds[i]].pool,
                startTime: incentiveKeys[incentiveIds[i]].startTime,
                endTime: incentiveKeys[incentiveIds[i]].endTime,
                refundee: incentiveKeys[incentiveIds[i]].refundee,
                token0: IUniswapV3Pool(incentiveKeys[incentiveIds[i]].pool).token0(),
                token1: IUniswapV3Pool(incentiveKeys[incentiveIds[i]].pool).token1(),
                totalRewardUnclaimed: incentives[incentiveIds[i]].totalRewardUnclaimed,
                totalSecondsClaimedX128: incentives[incentiveIds[i]].totalSecondsClaimedX128,
                numberOfStakes: incentives[incentiveIds[i]].numberOfStakes
            });
        }
    }

    function getIncentives(uint256 offset, uint256 limit) external view  returns (Incentive[] memory result) {
        uint256 end = offset + limit;
        if (end > incentiveIds.length) {
            end = incentiveIds.length;
        }
        result = new Incentive[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            result[i - offset] = incentives[incentiveIds[i]];
        }
    }

    function getDepositsByOwner(address owner) external view  returns (uint256[] memory result) {
        EnumerableSet.UintSet storage tokenIds = _tokenIdsByOwner[owner];
        result = new uint256[](tokenIds.length());
        for (uint256 i = 0; i < tokenIds.length(); i++) {
            result[i] = tokenIds.at(i);
        }
    }

    function getTokenIdsByOwner(address owner) external view  returns (uint256[] memory result) {
        EnumerableSet.UintSet storage tokenIds = _tokenIdsByOwner[owner];
        result = new uint256[](tokenIds.length());
        for (uint256 i = 0; i < tokenIds.length(); i++) {
            result[i] = tokenIds.at(i);
        }
    }

    /// @dev Stakes a deposited token without doing an ownership check
    function _stakeToken(IncentiveKey memory key, uint256 tokenId) private {
        require(block.timestamp >= key.startTime, 'AlphaPool::stakeToken: incentive not started');
        require(block.timestamp < key.endTime, 'AlphaPool::stakeToken: incentive ended');

        bytes32 incentiveId = IncentiveId.compute(key);

        require(
            incentives[incentiveId].totalRewardUnclaimed > 0,
            'AlphaPool::stakeToken: non-existent incentive'
        );
        require(
            _stakes[tokenId][incentiveId].liquidityNoOverflow == 0,
            'AlphaPool::stakeToken: token already staked'
        );

        (IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            NFTPositionInfo.getPositionInfo(factory, nonfungiblePositionManager, tokenId);

        require(pool == key.pool, 'AlphaPool::stakeToken: token pool is not the incentive pool');
        require(liquidity > 0, 'AlphaPool::stakeToken: cannot stake token with 0 liquidity');

        deposits[tokenId].numberOfStakes++;
        incentives[incentiveId].numberOfStakes++;

        (, uint160 secondsPerLiquidityInsideX128, ) = pool.snapshotCumulativesInside(tickLower, tickUpper);

        if (liquidity >= type(uint96).max) {
            _stakes[tokenId][incentiveId] = Stake({
                secondsPerLiquidityInsideInitialX128: secondsPerLiquidityInsideX128,
                liquidityNoOverflow: type(uint96).max,
                liquidityIfOverflow: liquidity
            });
        } else {
            Stake storage stake = _stakes[tokenId][incentiveId];
            stake.secondsPerLiquidityInsideInitialX128 = secondsPerLiquidityInsideX128;
            stake.liquidityNoOverflow = uint96(liquidity);
        }

        emit TokenStaked(tokenId, incentiveId, liquidity);
    }

    function emergencyWithdraw(IERC20Minimal token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        TransferHelperExtended.safeTransfer(address(token), to, amount);
    }

    function emergencyWithdrawNFT(uint256 tokenId, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId);
    }
}
