# Changelog

## [0.5.0](https://github.com/JorisJonkers-dev/estate/compare/v0.4.1...v0.5.0) (2026-10-14)


### Features

* **deliver:** open a GitHub Deployment on each moved Project's repository ([#57](https://github.com/JorisJonkers-dev/estate/issues/57)) ([0fcb54e](https://github.com/JorisJonkers-dev/estate/commit/0fcb54e980a08d1e1d916952a31936200f61bf61)), closes [#30](https://github.com/JorisJonkers-dev/estate/issues/30)
* **deliver:** report each delivery to production per Project, and fail on a refused one ([#53](https://github.com/JorisJonkers-dev/estate/issues/53)) ([e5517d1](https://github.com/JorisJonkers-dev/estate/commit/e5517d19a0f2ebba67ad0fe0c803c7778b334fdf))

## [0.4.1](https://github.com/JorisJonkers-dev/estate/compare/v0.4.0...v0.4.1) (2026-10-14)


### Bug Fixes

* **rollback:** fail closed where the backup or the proof could be skipped ([#49](https://github.com/JorisJonkers-dev/estate/issues/49)) ([cca7566](https://github.com/JorisJonkers-dev/estate/commit/cca7566f31a0239acf6a381d24aceec81840a6d3))

## [0.4.0](https://github.com/JorisJonkers-dev/estate/compare/v0.3.0...v0.4.0) (2026-10-14)


### Features

* **rollback:** roll a Project back to its proven release, after a backup through Flux ([#47](https://github.com/JorisJonkers-dev/estate/issues/47)) ([22843bb](https://github.com/JorisJonkers-dev/estate/commit/22843bb9acb9a3b8576cecf9dcde54c99a8d36af)), closes [#3](https://github.com/JorisJonkers-dev/estate/issues/3)

## [0.3.0](https://github.com/JorisJonkers-dev/estate/compare/v0.2.4...v0.3.0) (2026-10-14)


### Features

* **platform:** hold every release to a 1% error rate and 500ms latency, with deploy-kit 0.12.0 ([#44](https://github.com/JorisJonkers-dev/estate/issues/44)) ([8c7ddb5](https://github.com/JorisJonkers-dev/estate/commit/8c7ddb5fff2cece51dfd972c46138e01f02d4cf7)), closes [#36](https://github.com/JorisJonkers-dev/estate/issues/36)

## [0.2.4](https://github.com/JorisJonkers-dev/estate/compare/v0.2.3...v0.2.4) (2026-10-14)


### Bug Fixes

* **bootstrap:** store the Collector's key where the render reads it ([#42](https://github.com/JorisJonkers-dev/estate/issues/42)) ([1095176](https://github.com/JorisJonkers-dev/estate/commit/10951765c01659554313bb0227dcd5a8b21594ec))

## [0.2.3](https://github.com/JorisJonkers-dev/estate/compare/v0.2.2...v0.2.3) (2026-10-14)


### Bug Fixes

* **bootstrap:** apply Flagger's CRDs, which no render holds ([#39](https://github.com/JorisJonkers-dev/estate/issues/39)) ([fac623c](https://github.com/JorisJonkers-dev/estate/commit/fac623ce1c013533fc972872959ebf85ac3ad019))

## [0.2.2](https://github.com/JorisJonkers-dev/estate/compare/v0.2.1...v0.2.2) (2026-10-14)


### Bug Fixes

* **platform:** state where the old path runs Vault, so the policy job lands beside it ([#37](https://github.com/JorisJonkers-dev/estate/issues/37)) ([5efbea6](https://github.com/JorisJonkers-dev/estate/commit/5efbea6873cb645f9fe203377cc0e22c4c02e759))

## [0.2.1](https://github.com/JorisJonkers-dev/estate/compare/v0.2.0...v0.2.1) (2026-10-12)


### Bug Fixes

* name grimoire, tribelt, latex and knowledge-platform on the handover ledger ([#31](https://github.com/JorisJonkers-dev/estate/issues/31)) ([b393a28](https://github.com/JorisJonkers-dev/estate/commit/b393a28f265633c922bf2d16667b842f86d86f67))

## [0.2.0](https://github.com/JorisJonkers-dev/estate/compare/v0.1.1...v0.2.0) (2026-10-08)


### Features

* compose the estate, publish each moved Project's render and commit its pin ([#21](https://github.com/JorisJonkers-dev/estate/issues/21)) ([64ee3b1](https://github.com/JorisJonkers-dev/estate/commit/64ee3b1fc0f855352c84cc7f5fe986a22c9f4b05))
* **deploy:** pause and resume a Project by hand ([#25](https://github.com/JorisJonkers-dev/estate/issues/25)) ([6b0c513](https://github.com/JorisJonkers-dev/estate/commit/6b0c513653da33ef57af0cb28c0ef8bddc8b3ad9))
* list home-portal's Project app as a participant, and compose with deploy-kit 0.9.1 ([#26](https://github.com/JorisJonkers-dev/estate/issues/26)) ([47007d6](https://github.com/JorisJonkers-dev/estate/commit/47007d6e9f5c1f7e9dcea0cc7cec97b74a7a2a28))
* pull the renders with render-pull, compose with deploy-kit 0.10.0, and write the two unapplied pin sources again ([#29](https://github.com/JorisJonkers-dev/estate/issues/29)) ([60d135f](https://github.com/JorisJonkers-dev/estate/commit/60d135ff35c0946cf6d7d3a43594691747fd9c79))


### Bug Fixes

* **compose:** publish each artifact at the repository composition names, and read a pin's from its own source ([#28](https://github.com/JorisJonkers-dev/estate/issues/28)) ([217ca07](https://github.com/JorisJonkers-dev/estate/commit/217ca07b6e30f45c11215bd09bf1420f797399c0))
* **compose:** pull the Platform fragment beside, not into, the repository's platform directory ([#23](https://github.com/JorisJonkers-dev/estate/issues/23)) ([6b45278](https://github.com/JorisJonkers-dev/estate/commit/6b45278a6bb620e0fcc03de1cfaf98f363d64d60))

## [0.1.1](https://github.com/JorisJonkers-dev/estate/compare/v0.1.0...v0.1.1) (2026-10-07)


### Bug Fixes

* lock the backup method images and the Vault policy job ([#19](https://github.com/JorisJonkers-dev/estate/issues/19)) ([ef82ce1](https://github.com/JorisJonkers-dev/estate/commit/ef82ce17291d1363e00f1082490c77059e3b0d76))

## 0.1.0 (2026-10-07)


### Features

* bootstrap the estate repository and point Flux at it ([#7](https://github.com/JorisJonkers-dev/estate/issues/7)) ([c2c2115](https://github.com/JorisJonkers-dev/estate/commit/c2c211524027c6494437c380fada60b90a2be1ae))
* pin the canary render ([#8](https://github.com/JorisJonkers-dev/estate/issues/8)) ([f9fe182](https://github.com/JorisJonkers-dev/estate/commit/f9fe182f84cc145a3a04aac0f2d9e031053ab9b2))
* pin the node contract and the images lock the Platform fragment carries ([#13](https://github.com/JorisJonkers-dev/estate/issues/13)) ([8f8cf6c](https://github.com/JorisJonkers-dev/estate/commit/8f8cf6cdc72743fbb1ded00af06906d054e209a2))
* publish the Platform's fragments on each release ([#17](https://github.com/JorisJonkers-dev/estate/issues/17)) ([cb03424](https://github.com/JorisJonkers-dev/estate/commit/cb03424c6082f1272135d0ac7137e42f320849fd))
* state the Platform document's API access, policy job, engine surfaces and off-cluster target, and bootstrap the policy job's role ([#14](https://github.com/JorisJonkers-dev/estate/issues/14)) ([9b579a7](https://github.com/JorisJonkers-dev/estate/commit/9b579a74520e074f4922497100a3367148a2003a))


### Bug Fixes

* **bootstrap:** deny the policy job's role its own policy, the built-in policies and minting privileged roles ([#16](https://github.com/JorisJonkers-dev/estate/issues/16)) ([fe7d678](https://github.com/JorisJonkers-dev/estate/commit/fe7d678ec925cddf77d8f74170a9a4c9a2d846a7))
* **bootstrap:** keep the dispatch App on every repository, its id and key org-wide ([#10](https://github.com/JorisJonkers-dev/estate/issues/10)) ([bee835b](https://github.com/JorisJonkers-dev/estate/commit/bee835bb2b498940c3a0b6c1d3614aed4289bc27))
* **bootstrap:** read deploy keys through the REST API, whose read_only gh's --json drops ([#9](https://github.com/JorisJonkers-dev/estate/issues/9)) ([a798c14](https://github.com/JorisJonkers-dev/estate/commit/a798c144d5b763df34cf1050ccabfa0742b80949))
