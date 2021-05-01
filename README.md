# Migration Tools

Transfers DAO funds to a new one and old DAO tokenholders can claim new DAO tokens.

## How does it work?

To migrate the funds and create a claimable copy of the token we need migration tools installed in both DAOs (old DAO and new DAO). We also need to call the `migrate` function that will transfer the funds and create a old token snapshot. Tokenholders will be able to claim new tokens in the new DAO with the function `claimFor`.

## Initialization

The Migration Tools is initialized with `TokenManager _tokenManager`, `Vault _vault1`, and `Vault _vault2` parameters.
- The `TokenManager _tokenManager` is the address of the DAO main token manager of the DAO.
- The `Vault _vault1` parameter is the address of one of the vaults of the DAO.
- The `Vault _vault2` parameter is the address of the other vault of the DAO.

## Roles

The Migration Tools app implements the following role:
- **PREPARE_CLAIMS_ROLE**: Determines who can prepare the claims in the new DAO. It should be the migration tools of the old DAO.
- **MIGRATE_ROLE**: Determines who can migrate the funds from the old DAO.

The Migration Tools app should have the following roles:
- **TRANSFER_ROLE**: It should be able to transfer tokens from both vaults (just necessary in the old DAO).
- **ISSUE_ROLE** and **ASSIGN_ROLE**: It should be able to issue and assign vested tokens (just necessary in the new DAO).

## Interface

The Migration Tools app does not have an interface. It is meant as a back-end contract to be used with other Aragon applications.

## How to run Migration Tools locally

The Migration Tools app works in tandem with other Aragon applications. While we do not explore this functionality as a stand alone demo, the [Hatch template](https://github.com/CommonsSwarm/hatch-template) uses the Migration Tools and it can be run locally.

## Deploying to an Aragon DAO

TBD

## Contributing

We welcome community contributions!

Please check out our [open Issues](https://github.com/commonsswarm/migration-tools/issues) to get started.

If you discover something that could potentially impact security, please notify us immediately. The quickest way to reach us is via the #dev channel in our [Discord chat](https://discord.gg/n58U4hA). Just say hi and that you discovered a potential security vulnerability and we'll DM you to discuss details.
