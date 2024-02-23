import { HardhatUserConfig } from 'hardhat/config';
import '@nomicfoundation/hardhat-toolbox';
import * as dotenv from 'dotenv';
dotenv.config();

const config: HardhatUserConfig = {
  solidity: {
    version: '0.7.6',
    settings: {
      optimizer: {
        enabled: true,
        runs: 1_000_000,
      },
      metadata: {
        bytecodeHash: 'none',
      },
    },
  },
  networks: {
    ganache: {
      url: 'http://localhost:8545',
      gasPrice: 20000000000,
      accounts: [process.env.GANACHE_PRIVATE_KEY || ''],
    },
    testnet: {
      url: 'https://data-seed-prebsc-2-s1.binance.org:8545/',
      chainId: 97,
      gasPrice: 5000000000,
      accounts: [process.env.BNB_TESTNET_PRIVATE_KEY || ''],
    },
    // for mainnet
    blastMainnet: {
      url: 'coming end of February',
      accounts: [process.env.BLAST_MAINNET_PRIVATE_KEY || ''],
    },
    // for Sepolia testnet
    blastSepolia: {
      url: 'https://sepolia.blast.io',
      accounts: [process.env.BLAST_SEPOLIA_PRIVATE_KEY || ''],
    },
  },
  etherscan: {
    apiKey: {
      blastSepolia: 'your API key',
    },
    customChains: [
      {
        network: 'blastSepolia',
        chainId: 168587773,
        urls: {
          apiURL:
            'https://api.routescan.io/v2/network/testnet/evm/168587773/etherscan',
          browserURL: 'https://testnet.blastscan.io',
        },
      },
    ],
  },
  sourcify: {
    enabled: true,
  },
};

export default config;
