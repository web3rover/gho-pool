# AAVE GHO Pool

This project demonstrates design of smart contracts system that allows stkAave holders to sell their discount on GHO borrow rate.

To run the forked e2e tests you need to get RPC URL from Alchemy for Goerli testnet. Then copy it to the `.env.example` file. After than run the following command:

```
cp .env.example .env
npx hardhat test
```