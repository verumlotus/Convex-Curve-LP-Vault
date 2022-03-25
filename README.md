# Convex Curve LP Vault

Vault for depositing Curve LP tokens that will harvest rewards leveraging Convex's system. 

## Background

Convex has cornered the market in the context of the Curve Wars. Thus, to maximize yield on a Curve LP position, the best option is to leverage Convex's system and deposit LP tokens in their ecosystem. This allows Curve LP token holders to earn CRV & CVX emissions, along with other emissions protocols may choose to give LPs. This vault accepts Curve LP tokens, deposits them in Convex's Booster contract, & stakes them in the Convex Reward pool. Keepers are authorized by the contract owner to call the `harvest()` function to collect token emissions. They are incentivized with a configurable `keeperFee` which represents a percentage of the reward tokens. A diagram is provided below to help understand the flow.

<img width="1112" alt="Screen Shot 2022-03-25 at 12 19 56 PM" src="https://user-images.githubusercontent.com/97858468/160187466-24dd7b68-eec3-4659-9c39-2c5a462f967d.png">

## User flow
- User can call `deposit` to deposit the Curve LP token & receive shares from the vault.
- User can call `withdraw` at any time to burn shares & receive an appropriate amount of LP tokens from the vault.

## Management Flow
- The owner can set authorized addresses via `authorize`. Authorized addresses can perform important functions such as setting Uniswap V3 swap paths. 
- An authorized harvester can call the `harvest()` function when profitable to collect rewards. They receive a percentage of rewards (set by `keeperFee`) in the form of underlying LP tokens.

## Build & Testing
This repo uses hardhat as the build & testing framework. Additionally, it also utilizes some contracts from balancer-v2, which can be downloaded via running the shell script located at `scripts/load-balancer-contracts.sh`. Run `npm run build` to build the repo & `npm run test` to run the test suite. The tests fork from mainnet via alchemy, and thus an alchemy api key must be exposed via an environment variable of the name `ALCHEMY_KEY`. A `.env.example` file is provided as an example. 

## Improvements
Curve has an idiosyncratic design, and the interfaces for contracts are not identical. Thus, a small part of the logic in this vault is specific to the LUSD-3CRV pool. Notably, the `add_liquidity` function differs slightly for different Curve pools. However, only a few lines would need to be changed to support other Curve LP tokens. In the future, a standard interface to all Curve pools could be designed to make this more extensible. 

## Disclaimer
These contracts were written in mind for Element Finance as a new yield source. A PR will be opened in the Element Finance repo, and will undergo review by Element Finance core members before being merged & deployed. Any changes there are not guaranteed to be updated here. The contracts in this repo as they are now should not be deployed to production without more thorough review.
