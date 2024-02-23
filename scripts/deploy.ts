import { ethers } from 'hardhat';

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log('Deploying contracts with the account:', deployer.address);
  const v3Factory = '0xbAB2F66B5B3Be3cC158E3aC1007A8DF0bA5d67F4';
  const nonfungiblePositionManager =
    '0xa4b568bCdeD46bB8F84148fcccdeA37e262A3848';
  const maxIncentiveStartLeadTime = 30 * 86400;
  const maxIncentiveDuration = 365 * 86400;

  // const alphaPool = await ethers.deployContract('AlphaPool', [
  //   v3Factory,
  //   nonfungiblePositionManager,
  //   maxIncentiveStartLeadTime,
  //   maxIncentiveDuration,
  // ]);
  const alphaPool = await ethers.getContractAt(
    'AlphaPool',
    '0x0E1648D4dD7Ebac7ceA38Fae3af2c64977439bBa'
  );
  console.log(
    `alphaPool deployed ${await alphaPool.getAddress()} "${v3Factory}" "${nonfungiblePositionManager}" "${maxIncentiveStartLeadTime}" "${maxIncentiveDuration}"`
  );
  const tMono = await ethers.getContractAt(
    'TestERC20',
    '0xa07aC8cDe2a98B189477b8e41F0c2Ea6CdDbC055'
  );
  // const tMono = await ethers.deployContract('TestERC20', [
  //   ethers.parseEther('10000000000'),
  // ]);
  const poolAddress = '0xC382B3DE9d67070fff2b9635d3A67Ef1b7f04c3e';
  const poolFee = 3000;
  const startTime = Math.floor(Date.now() / 1000) + 60;
  const endTime = startTime + 86400 * 10;

  console.log(`Approving AlphaPool ${await alphaPool.getAddress()}`);
  await tMono.approve(
    await alphaPool.getAddress(),
    ethers.parseEther('1000000')
  );

  console.log(
    `Creating Incentive for AlphaPool, Key: [${await tMono.getAddress()}, ${poolAddress}, ${startTime}, ${endTime}, ${
      deployer.address
    }]`
  );
  await alphaPool.createIncentive(
    {
      rewardToken: await tMono.getAddress(),
      pool: poolAddress,
      startTime: startTime,
      endTime: endTime,
      refundee: deployer.address,
    },
    ethers.parseEther('10000')
  );
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
