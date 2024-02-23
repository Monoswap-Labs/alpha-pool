import { ethers } from 'hardhat';
import { MonoswapV3Staker } from '../typechain-types';

async function main() {
  const [deployer] = await ethers.getSigners();
  const rewardToken = '0xa07aC8cDe2a98B189477b8e41F0c2Ea6CdDbC055';
  const poolAddress = '0xC382B3DE9d67070fff2b9635d3A67Ef1b7f04c3e';
  const startTime = 1708069500;
  const endTime = 1708071300;
  const refundee = '0xca640e70E1822096aa42a79A363D7849CD34664C';
  const coder = new ethers.AbiCoder();

  const calldata = coder.encode(
    ['address', 'address', 'uint256', 'uint256', 'address'],
    [rewardToken, poolAddress, startTime, endTime, refundee]
  );
  console.log('calldata:', calldata);

  const monoSwapStaker = await ethers.getContractAt(
    'MonoswapV3Staker',
    '0xF382b5B3E5A0Ad86D130717325F6B7F3373AA742'
  );
  const nft = await ethers.getContractAt(
    'IERC721',
    '0xa4b568bCdeD46bB8F84148fcccdeA37e262A3848'
  );
  console.log('Transfering NFT to MonoswapV3Staker');
  await nft.safeTransferFrom(
    deployer.address,
    await monoSwapStaker.getAddress(),
    7707
  );
  console.log('Stake NFT');
  await monoSwapStaker.stakeToken(
    {
      rewardToken: rewardToken,
      pool: poolAddress,
      startTime: startTime,
      endTime: endTime,
      refundee: refundee,
    },
    7707
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
