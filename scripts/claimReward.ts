import { ethers } from 'hardhat';

async function main() {
  const rewardToken = '0xa07aC8cDe2a98B189477b8e41F0c2Ea6CdDbC055';
  const poolAddress = '0xC382B3DE9d67070fff2b9635d3A67Ef1b7f04c3e';
  const startTime = 1708084800;
  const endTime = 1708776000;
  const refundee = '0xca640e70E1822096aa42a79A363D7849CD34664C';
  const tokenId = '82003';

  const alphaPool = await ethers.getContractAt(
    'AlphaPool',
    '0xE91EA89B31beC2AF35a40D9f593D6373C99e4C94'
  );

  const unstakeCalldata = alphaPool.interface.encodeFunctionData(
    'unstakeToken',
    [
      {
        rewardToken: rewardToken,
        pool: poolAddress,
        startTime: startTime,
        endTime: endTime,
        refundee: refundee,
      },
      tokenId,
    ]
  );
  const claimRewardCalldata = alphaPool.interface.encodeFunctionData(
    'claimReward',
    [rewardToken, refundee, ethers.MaxUint256]
  );
  const stakeTokenCalldata = alphaPool.interface.encodeFunctionData(
    'stakeToken',
    [
      {
        rewardToken: rewardToken,
        pool: poolAddress,
        startTime: startTime,
        endTime: endTime,
        refundee: refundee,
      },
      tokenId,
    ]
  );
  console.log(
    `Calldata: [${unstakeCalldata}, ${claimRewardCalldata}, ${stakeTokenCalldata}]`
  );
  const tx = await alphaPool.multicall([
    unstakeCalldata,
    claimRewardCalldata,
    stakeTokenCalldata,
  ]);
  console.log('tx:', tx.hash);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
