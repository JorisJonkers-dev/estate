# Changelog

## [0.23.0](https://github.com/JorisJonkers-dev/estate/compare/v0.22.4...v0.23.0) (2026-10-19)


### Features

* hand jellyfin and jellyseerr over to the estate path, with nvidia's GPU request and deploy-kit 0.21.0 ([#164](https://github.com/JorisJonkers-dev/estate/issues/164)) ([b2cf108](https://github.com/JorisJonkers-dev/estate/commit/b2cf108a8f1a5ca7a576113c09e666d9f22cfcfa))

## [0.22.4](https://github.com/JorisJonkers-dev/estate/compare/v0.22.3...v0.22.4) (2026-10-19)


### Bug Fixes

* run deploy-kit 0.20.0, which carries the release label in the rendered artifact ([#160](https://github.com/JorisJonkers-dev/estate/issues/160)) ([c694aee](https://github.com/JorisJonkers-dev/estate/commit/c694aee2b1e60aa1a5983b525c82da53be1fa40f))

## [0.22.3](https://github.com/JorisJonkers-dev/estate/compare/v0.22.2...v0.22.3) (2026-10-19)


### Bug Fixes

* compose from main as it is, and push the pin commit over a ClusterState capture ([#149](https://github.com/JorisJonkers-dev/estate/issues/149)) ([acd28a6](https://github.com/JorisJonkers-dev/estate/commit/acd28a6b1f837831fb2cdf6e7b3f8e7a7af1700f))
* run deploy-kit 0.19.3, which backs up a files volume as the Process that owns it ([#159](https://github.com/JorisJonkers-dev/estate/issues/159)) ([6b7b6bc](https://github.com/JorisJonkers-dev/estate/commit/6b7b6bcfa7dab1956b2443ec46ebea9201345220))

## [0.22.2](https://github.com/JorisJonkers-dev/estate/compare/v0.22.1...v0.22.2) (2026-10-18)


### Bug Fixes

* run the backup methods from delivery 0.9.2, whose pg_dumpall finds pg_dump ([#155](https://github.com/JorisJonkers-dev/estate/issues/155)) ([1f5a803](https://github.com/JorisJonkers-dev/estate/commit/1f5a803a4e967d1a2da1cfabe4771013f4dc019e))

## [0.22.1](https://github.com/JorisJonkers-dev/estate/compare/v0.22.0...v0.22.1) (2026-10-18)


### Bug Fixes

* run the backup methods from delivery 0.9.1, which take the peer the render hands them ([#153](https://github.com/JorisJonkers-dev/estate/issues/153)) ([217da12](https://github.com/JorisJonkers-dev/estate/commit/217da122f032e26036f83541677e8ce41796604a))

## [0.22.0](https://github.com/JorisJonkers-dev/estate/compare/v0.21.0...v0.22.0) (2026-10-18)


### Features

* deliver the arr stack on the estate path, mounting the media library ([#151](https://github.com/JorisJonkers-dev/estate/issues/151)) ([1117972](https://github.com/JorisJonkers-dev/estate/commit/1117972501f2a2098f71a50ac889c680bbe6a719))

## [0.21.0](https://github.com/JorisJonkers-dev/estate/compare/v0.20.2...v0.21.0) (2026-10-18)


### Features

* deliver immich on the estate path ([#143](https://github.com/JorisJonkers-dev/estate/issues/143)) ([4b0878b](https://github.com/JorisJonkers-dev/estate/commit/4b0878bf6e37bba2d62df277d57635fbab7797e6))

## [0.20.2](https://github.com/JorisJonkers-dev/estate/compare/v0.20.1...v0.20.2) (2026-10-18)


### Bug Fixes

* publish fragments with deploy-kit 0.19.2, which knows the substrate's image pull ([#145](https://github.com/JorisJonkers-dev/estate/issues/145)) ([5df430f](https://github.com/JorisJonkers-dev/estate/commit/5df430f2aaa161cfcf5bef23ed56ff30737aee33))

## [0.20.1](https://github.com/JorisJonkers-dev/estate/compare/v0.20.0...v0.20.1) (2026-10-18)


### Bug Fixes

* run deploy-kit 0.19.0, which retries the Vault policy job and keeps it off the SD cards ([#141](https://github.com/JorisJonkers-dev/estate/issues/141)) ([ab48690](https://github.com/JorisJonkers-dev/estate/commit/ab48690916172dfa7533b4f493b980bd27832108))
* run deploy-kit 0.19.2, and allow five minutes for an image pull ([#144](https://github.com/JorisJonkers-dev/estate/issues/144)) ([8a25f21](https://github.com/JorisJonkers-dev/estate/commit/8a25f21c63b12a1bf1b777f429f5b8746e4b7171))

## [0.20.0](https://github.com/JorisJonkers-dev/estate/compare/v0.19.0...v0.20.0) (2026-10-17)


### Features

* declare the media library, and run deploy-kit 0.19.0 ([#139](https://github.com/JorisJonkers-dev/estate/issues/139)) ([a2f526a](https://github.com/JorisJonkers-dev/estate/commit/a2f526a08a14a78a1bbc24035cbbe000a6a0c820))


### Bug Fixes

* give the Vault policy job five minutes per run ([#137](https://github.com/JorisJonkers-dev/estate/issues/137)) ([7904e53](https://github.com/JorisJonkers-dev/estate/commit/7904e535adb5ada87c63f54cc02e9af0ddd7aa58))

## [0.19.0](https://github.com/JorisJonkers-dev/estate/compare/v0.18.0...v0.19.0) (2026-10-17)


### Features

* deliver karakeep on the estate path ([#135](https://github.com/JorisJonkers-dev/estate/issues/135)) ([514a528](https://github.com/JorisJonkers-dev/estate/commit/514a52842e5a7acef8c146473e23b4fbc926caa9))

## [0.18.0](https://github.com/JorisJonkers-dev/estate/compare/v0.17.0...v0.18.0) (2026-10-17)


### Features

* deliver hindsight on the estate path ([#132](https://github.com/JorisJonkers-dev/estate/issues/132)) ([758fd4c](https://github.com/JorisJonkers-dev/estate/commit/758fd4c0293b303f7d0bdb9ea889a629b0b44c94))

## [0.17.0](https://github.com/JorisJonkers-dev/estate/compare/v0.16.0...v0.17.0) (2026-10-17)


### Features

* compose hindsight's Intent Fragment ([#130](https://github.com/JorisJonkers-dev/estate/issues/130)) ([ee0ba7a](https://github.com/JorisJonkers-dev/estate/commit/ee0ba7ab2c01666c8d70c83b91ec51eb3d82bad7))


### Bug Fixes

* tag the composed lock latest only after it is signed and verified ([#127](https://github.com/JorisJonkers-dev/estate/issues/127)) ([7a37775](https://github.com/JorisJonkers-dev/estate/commit/7a37775192f183283662288a5fcf077f15f9b7f8))

## [0.16.0](https://github.com/JorisJonkers-dev/estate/compare/v0.15.2...v0.16.0) (2026-10-16)


### Features

* compose overleaf's Intent Fragment ([#124](https://github.com/JorisJonkers-dev/estate/issues/124)) ([4b19e5b](https://github.com/JorisJonkers-dev/estate/commit/4b19e5be5a4fa5546396d9f6d6f21a31eb6e1688))
* deliver overleaf on the estate path ([#126](https://github.com/JorisJonkers-dev/estate/issues/126)) ([2d3449b](https://github.com/JorisJonkers-dev/estate/commit/2d3449b5888a52fb975a714743f5004ecf105788))

## [0.15.2](https://github.com/JorisJonkers-dev/estate/compare/v0.15.1...v0.15.2) (2026-10-16)


### Bug Fixes

* let outline run on any node ([#121](https://github.com/JorisJonkers-dev/estate/issues/121)) ([b1b5f16](https://github.com/JorisJonkers-dev/estate/commit/b1b5f167b611a2999855db3b66fa777a2e7260f2))

## [0.15.1](https://github.com/JorisJonkers-dev/estate/compare/v0.15.0...v0.15.1) (2026-10-16)


### Bug Fixes

* run outline in Frankfurt, beside the datastores it reads ([#119](https://github.com/JorisJonkers-dev/estate/issues/119)) ([3b437c3](https://github.com/JorisJonkers-dev/estate/commit/3b437c3eb8cfd5f7d384202014ee4aaaa5c388aa))

## [0.15.0](https://github.com/JorisJonkers-dev/estate/compare/v0.14.0...v0.15.0) (2026-10-16)


### Features

* deliver outline on the estate path ([#117](https://github.com/JorisJonkers-dev/estate/issues/117)) ([69deb5f](https://github.com/JorisJonkers-dev/estate/commit/69deb5f833f4e230c1ca4fa542d63ce8595fab0f))

## [0.14.0](https://github.com/JorisJonkers-dev/estate/compare/v0.13.1...v0.14.0) (2026-10-16)


### Features

* publish outline's Intent Fragment from this repository ([#114](https://github.com/JorisJonkers-dev/estate/issues/114)) ([e9fd2b7](https://github.com/JorisJonkers-dev/estate/commit/e9fd2b7703dda00178005c0051e82dfa5d49b295))

## [0.13.1](https://github.com/JorisJonkers-dev/estate/compare/v0.13.0...v0.13.1) (2026-10-16)


### Bug Fixes

* publish the Platform fragment with deploy-kit 0.18.0 ([#109](https://github.com/JorisJonkers-dev/estate/issues/109)) ([977bbe5](https://github.com/JorisJonkers-dev/estate/commit/977bbe5b412ca2504e53b472d29590b1316c8477))

## [0.13.0](https://github.com/JorisJonkers-dev/estate/compare/v0.12.2...v0.13.0) (2026-10-16)


### Features

* deliver grimoire on the estate path ([#108](https://github.com/JorisJonkers-dev/estate/issues/108)) ([a5e4485](https://github.com/JorisJonkers-dev/estate/commit/a5e4485ff52eaf8710045137163a577c794a5a59))


### Bug Fixes

* run deploy-kit 0.18.0, which delivers the database credential an edge derives ([#106](https://github.com/JorisJonkers-dev/estate/issues/106)) ([107cf43](https://github.com/JorisJonkers-dev/estate/commit/107cf439f8725def9e2635e11226afcae16dd75c))

## [0.12.2](https://github.com/JorisJonkers-dev/estate/compare/v0.12.1...v0.12.2) (2026-10-16)


### Bug Fixes

* run the Vault policy job from delivery 0.9.1, which writes the catalog method's policy ([#104](https://github.com/JorisJonkers-dev/estate/issues/104)) ([06e0506](https://github.com/JorisJonkers-dev/estate/commit/06e0506963dc36f05bfd8b0b423beb5a9d846bde))

## [0.12.1](https://github.com/JorisJonkers-dev/estate/compare/v0.12.0...v0.12.1) (2026-10-16)


### Bug Fixes

* **release:** publish the Platform fragment with deploy-kit 0.17.0 ([#102](https://github.com/JorisJonkers-dev/estate/issues/102)) ([a3f162c](https://github.com/JorisJonkers-dev/estate/commit/a3f162c5f2ab012140cedaac1dd8da2b5cc565d1))

## [0.12.0](https://github.com/JorisJonkers-dev/estate/compare/v0.11.0...v0.12.0) (2026-10-16)


### Features

* apply the estate path's database catalog with deploy-kit 0.17.0 ([#101](https://github.com/JorisJonkers-dev/estate/issues/101)) ([c15284b](https://github.com/JorisJonkers-dev/estate/commit/c15284bbd1ebe5d23c6be2e823ac477ab32921c9))
* run the Vault policy job from delivery 0.8.0, which adopts a generated key's old value ([#99](https://github.com/JorisJonkers-dev/estate/issues/99)) ([c74cd7e](https://github.com/JorisJonkers-dev/estate/commit/c74cd7e5867a97182f64eed2d3e6ba0395852410))

## [0.11.0](https://github.com/JorisJonkers-dev/estate/compare/v0.10.0...v0.11.0) (2026-10-15)


### Features

* let the Vault policy job write generated keys ([#94](https://github.com/JorisJonkers-dev/estate/issues/94)) ([d48bb4a](https://github.com/JorisJonkers-dev/estate/commit/d48bb4ab14e0b57bf885897e38d83fca5bc7da6a))
* run deploy-kit 0.16.0, which generates declared secret keys ([#97](https://github.com/JorisJonkers-dev/estate/issues/97)) ([f7758a6](https://github.com/JorisJonkers-dev/estate/commit/f7758a66d8b428f4464d6953a1338fb993783783))
* run the Vault policy job from delivery 0.7.0, which writes generated keys ([#98](https://github.com/JorisJonkers-dev/estate/issues/98)) ([7928163](https://github.com/JorisJonkers-dev/estate/commit/79281632cc794d4aa45e9943b352e7e5f25a2c5a))

## [0.10.0](https://github.com/JorisJonkers-dev/estate/compare/v0.9.1...v0.10.0) (2026-10-15)


### Features

* deliver tribelt on the estate path ([#92](https://github.com/JorisJonkers-dev/estate/issues/92)) ([92090df](https://github.com/JorisJonkers-dev/estate/commit/92090dfea14f9dc7ad9c417b3657ff69920f97f8))

## [0.9.1](https://github.com/JorisJonkers-dev/estate/compare/v0.9.0...v0.9.1) (2026-10-15)


### Bug Fixes

* stop reading home-portal's old app fragment ([#89](https://github.com/JorisJonkers-dev/estate/issues/89)) ([f20674a](https://github.com/JorisJonkers-dev/estate/commit/f20674ae166f7f9d9ca763e1f3a8875281ee796a))

## [0.9.0](https://github.com/JorisJonkers-dev/estate/compare/v0.8.0...v0.9.0) (2026-10-15)


### Features

* deliver home-portal on the estate path ([#88](https://github.com/JorisJonkers-dev/estate/issues/88)) ([0fffc1d](https://github.com/JorisJonkers-dev/estate/commit/0fffc1d67d94b7bb11597af8c80a9fbb1b180303))
* pin the toolkit in toolkit.yml, at deploy-kit 0.15.0, without a package.json ([#83](https://github.com/JorisJonkers-dev/estate/issues/83)) ([9b0a7c6](https://github.com/JorisJonkers-dev/estate/commit/9b0a7c611a00e5d91b0af5ff6b33c02faed04956))

## [0.8.0](https://github.com/JorisJonkers-dev/estate/compare/v0.7.1...v0.8.0) (2026-10-15)


### Features

* **bootstrap:** create the estate-dashboard's database and write its URL to Vault ([#75](https://github.com/JorisJonkers-dev/estate/issues/75)) ([563928a](https://github.com/JorisJonkers-dev/estate/commit/563928a5fdbc74eeda2df834ec154a5153491b46))
* deliver the estate-dashboard on the estate path ([#77](https://github.com/JorisJonkers-dev/estate/issues/77)) ([9f160b5](https://github.com/JorisJonkers-dev/estate/commit/9f160b5155ea7f1c51bd14d276b9171b037ff025))

## [0.7.1](https://github.com/JorisJonkers-dev/estate/compare/v0.7.0...v0.7.1) (2026-10-15)


### Bug Fixes

* hand the data fragment's validation its config and env ([#73](https://github.com/JorisJonkers-dev/estate/issues/73)) ([04e8680](https://github.com/JorisJonkers-dev/estate/commit/04e868029fc368ff0d1ef105e6024b313b4fb626))

## [0.7.0](https://github.com/JorisJonkers-dev/estate/compare/v0.6.0...v0.7.0) (2026-10-15)


### Features

* publish the data and mail fragments as legacy participants ([#69](https://github.com/JorisJonkers-dev/estate/issues/69)) ([ee05c1d](https://github.com/JorisJonkers-dev/estate/commit/ee05c1d99ec38433565ea4b233976aca45231125)), closes [#68](https://github.com/JorisJonkers-dev/estate/issues/68)


### Bug Fixes

* **bootstrap:** wait for an App's installation, and name where GitHub keeps its keys now ([#65](https://github.com/JorisJonkers-dev/estate/issues/65)) ([b1ed446](https://github.com/JorisJonkers-dev/estate/commit/b1ed4467f595aa234b38ee60539ac04cf0a1b94a))
* **bootstrap:** write the estate-dashboard's sign-in document where its project file reads it ([#67](https://github.com/JorisJonkers-dev/estate/issues/67)) ([00d58e4](https://github.com/JorisJonkers-dev/estate/commit/00d58e46f8b3729a60da7d0cf251dd746f86a692))

## [0.6.0](https://github.com/JorisJonkers-dev/estate/compare/v0.5.0...v0.6.0) (2026-10-14)


### Features

* **bootstrap:** create the Reporter App and keep its key in Vault ([#61](https://github.com/JorisJonkers-dev/estate/issues/61)) ([d17a2ba](https://github.com/JorisJonkers-dev/estate/commit/d17a2ba46d8efcfbd70ca6d4924b664be146b53f))
* name the Reporter, and admit its API access ([#64](https://github.com/JorisJonkers-dev/estate/issues/64)) ([2704c4c](https://github.com/JorisJonkers-dev/estate/commit/2704c4c2fc0b7203c230a368a0696a567dc30953))

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
