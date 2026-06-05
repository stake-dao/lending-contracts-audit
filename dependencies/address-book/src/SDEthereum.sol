// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

library Core {
    /// Token addresses and revenue sharing.
    address internal constant SDT = 0x73968b9a57c6E53d41345FD57a6E6ae27d6CDB2F;
    address internal constant VESDT = 0x0C30476f66034E11782938DF8e4384970B6c9e8a;
    address internal constant VESDT_BOOST_PROXY = 0xD67bdBefF01Fc492f1864E61756E5FBB3f173506;
    address internal constant VEBOOST = 0x47B3262C96BB55A8D2E4F8E3Fed29D2eAB6dB6e9;
    address internal constant VLSDT = 0x94818A7baa7e9F5dC62ce4da1B52ef9a760b80B8;
    address internal constant VLBOOST = 0xaB05ca46d1c78CAbB051efFE35099714Cad2AddA;
    address internal constant BOOST_MARKETPLACE = 0xbc38D256E559FEd3fA95A6cdC633C667283fb6b8;
    address internal constant VESDT_IMPLEMENTATION = 0x09943C4f27f2aDA5BB58b845d27405a4b3A894a8;
    address internal constant UNIFORM_BOOST_PROVIDER = 0x7c3867E04d5A69B750332300643B36135313c5B7;
    address internal constant VLSDT_FEE_DISTRIBUTOR_SDT = 0x6d57d34259F6dc31C9a241c199822861940d38f9;
    address internal constant VLSDT_FEE_DISTRIBUTOR_USDC = 0xCa94395469a88E9cAC0D5E5e308910E298270d30;
    address internal constant FEE_DISTRIBUTOR = 0x29f3dd38dB24d3935CF1bf841e6b2B461A3E5D92;
    address internal constant FEE_DISTRIBUTOR_USDC = 0xC126bf16CECC6825D87b74287534cD97b3538073;
    address internal constant PROXY_ADMIN = 0xfE612c237A81527a86f2Cac1FD19939CF4F91B9B;
    address internal constant SMART_WALLET_CHECKER = 0x37E8386602d9EBEa2c56dd11d8E142290595f1b5;
    address internal constant TIMELOCK = 0xD3cFc4E65a73BB6C482383EB38f5C3E1d1411616;

    /// Recipient
    address internal constant TREASURY = 0x9EBBb3d59d53D6aD3FA5464f36c2E84aBb7cf5c1;
    address internal constant VESDT_FEES_RECIPIENT = 0x1fE537BD59A221854a53a5B7a81585B572787fce;
    address internal constant LIQUIDITY_FEES_RECIPIENT = 0x576D7AD8eAE92D9A972104Aac56c15255dDBE080;
    address internal constant STRATEGY_FEES_RECIPIENT = 0x239Fe53F10Fe77E9C6ed896E3Ae4aB8E43EeD082;
    address internal constant FEE_RECEIVER = 0x60136fefE23D269aF41aB72DE483D186dC4318D6;

    /// SDT Distribution.
    address internal constant LOCKER_SDT_DISTRIBUTOR = 0x8Dc551B4f5203b51b5366578F42060666D42AB5E;
    address internal constant STRATEGY_SDT_DISTRIBUTOR = 0x9C99dffC1De1AfF7E7C1F36fCdD49063A281e18C;
    address internal constant LOCKER_GAUGE_CONTROLLER = 0x75f8f7fa4b6DA6De9F4fE972c811b778cefce882;
    address internal constant STRATEGY_GAUGE_CONTROLLER = 0x3F3F0776D411eb97Cfa4E3eb25F33c01ca4e7Ca8;

    /// veSDT on-chain voting addreses.
    address internal constant AGENT_APP = 0x30f9fFF0f55d21D666E28E650d0Eb989cA44e339;
    address internal constant VOTING_APP = 0x82e631fe565E06ea51a00fAbcd79645272f654eB;

    /// Votes modules
    address internal constant CURVE_VOTER = 0xb118fbE8B01dB24EdE7E87DFD19693cfca13e992;

    /// Merkles distributors
    address internal constant SD_TOKENS_MERKLE = 0x03E34b085C52985F6a5D27243F20C84bDdc01Db4;
    address internal constant VLCVX_THURSDAY_MERKLE = 0x000000006feeE0b7a0564Cd5CeB283e10347C4Db;
    address internal constant VLCVX_TUESDAY_MERKLE = 0x17F513CDE031C8B1E878Bde1Cb020cE29f77f380;
    address internal constant MISC_MERKLE = 0x6D98023de9AdeEE661E922F58f5c2ff086be1F4e;
    address internal constant SDCRV_BOUNTY_MERKLE = 0x32dA29D7F3aD8cF157C6427CecFD3f0665042A37;
    address internal constant SDFXN_BOUNTY_MERKLE = 0xdD03449c5b8F1e2aF92FaA45Db6CCA268479b990;

    /// Common addresses
    address internal constant GOVERNANCE = 0xB0552b6860CE5C0202976Db056b5e3Cc4f9CC765;
    address internal constant LAPOSTE = 0xF0000058000021003E4754dCA700C766DE7601C2;
    address internal constant L2_SAFE_TREASURY = 0x5DA07af8913A4EAf09E5F569c20138b658906c17;
    address internal constant VOTIUM_FORWARDER_RECIPIENT = 0xAe86A3993D13C8D77Ab77dBB8ccdb9b7Bc18cd09;
    address internal constant DEPLOYER = 0x000755Fbe4A24d7478bfcFC1E561AfCE82d1ff62;

    // Automation
    address internal constant ALL_MIGHT = 0x0000000a3Fc396B89e4c11841B39D9dff85a5D05;
    address internal constant ALL_MIGHT_V2 = 0x9B3C89f4bfda2b07E15A7cF45C3F092b4b3ca074;
    address internal constant BOTMARKET = 0xADfBFd06633eB92fc9b58b3152Fe92B0A24eB1FF;
    address internal constant AUTOMATION = 0x90569D8A1cF801709577B24dA526118f0C83Fc75;
}

library Router {
    address internal constant STAKEDAO_ROUTER = 0x0f542fA75c871EB1b93Ef881b73e46acF733392f;
    address internal constant ROUTER_MODULE_VLSDT = 0x8155B8858Af2b12baf8A79E22021B14f91557707;
}

library Votemarket {
    address internal constant CAMPAIGN_REMOTE_MANAGER = 0x53aD4Cd1F1e52DD02aa9FC4A8250A1b74F351CA2;
}

library Lending {
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant MORPHO_ADAPTIVE_CURVE_IRM = 0x870aC11D48B15DB9a138Cf899d20F13F79Ba00BC;
    address internal constant MORPHO_CHAINLINK_ORACLE_FACTORY = 0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766;
    address internal constant MORPHO_META_MORPHO_FACTORY = 0x1897A8997241C1cD4bD0698647e4EB7213535c24;

    ///////////////////////////////////////////////////////////////
    // --- USDC VAULTS/MARKETS
    ///////////////////////////////////////////////////////////////

    address internal constant STAKEDAO_VAULT_USDC_V1 = 0x13AA4f80AD5F06cE4f1A3a3cA58C37059F0EE4c5;
    address internal constant STAKEDAO_VAULT_USDC_V2 = 0x8EDCC305E633d29BFB383872e79401c506cE9E6f;

    // Llamaland sREUSD/USDC market https://app.morpho.org/ethereum/market/0x9c1f0e3cb1c0b7ecbecf983e8ebe7c81599b3fb4c3a60b6a39fa03fc1ba5dc8e
    address internal constant MARKET_LLSREUSD_USDC_ORACLE = 0xCc00d98162fEf57d6A1057a36C25D5326e3805c8;
    address internal constant MARKET_LLSREUSD_USDC_COLLATERAL = 0x6aEe69A11D5fB0e71c813Fe8419D84b12FB11FdA;
    bytes32 internal constant MARKET_LLSREUSD_USDC_ID =
        0x9c1f0e3cb1c0b7ecbecf983e8ebe7c81599b3fb4c3a60b6a39fa03fc1ba5dc8e;

    // Curve USDC/crvUSD market https://app.morpho.org/ethereum/market/0x7e66ce6d3e2a27db0dab1d9c16dd313a4658eb6317a75d3bf8de8fe8a5880f96
    address internal constant MARKET_USDCCRVUSD_USDC_ORACLE = 0x3bb43EF3EBF21E84c38e958fbF85af482d594C77;
    address internal constant MARKET_USDCCRVUSD_USDC_COLLATERAL = 0x393C0cf85E5a60b730e705396f3bea71648FA3A0;
    bytes32 internal constant MARKET_USDCCRVUSD_USDC_ID =
        0x7e66ce6d3e2a27db0dab1d9c16dd313a4658eb6317a75d3bf8de8fe8a5880f96;

    // Curve USDT/crvUSD market https://app.morpho.org/ethereum/market/0x68d35b050f930a801087aa0aca91da1bc32f84783277813b619e3e1d0bf00a2f
    address internal constant MARKET_USDTCRVUSD_USDC_ORACLE = 0x0833501FC146846D651D8F073e79a23bfB8193Ae;
    address internal constant MARKET_USDTCRVUSD_USDC_COLLATERAL = 0x92abCF6813150a9F78540cAa4feE6115a713F505;
    bytes32 internal constant MARKET_USDTCRVUSD_USDC_ID =
        0x68d35b050f930a801087aa0aca91da1bc32f84783277813b619e3e1d0bf00a2f;

    // Curve frxUSD/crvUSD market https://app.morpho.org/ethereum/market/0xa67cfcdf2a2637c78fd6e1879e27448be7abe90c6ef1be4a1ca4337db886c8e3
    address internal constant MARKET_FRXUSDCRVUSD_USDC_ORACLE = 0x70979F4Ad0Cd9d894d73bc747Cc8DD7a269B5551;
    address internal constant MARKET_FRXUSDCRVUSD_USDC_COLLATERAL = 0xF7dAf52958690F1dc89CD377d638e9Fc94E76ACF;
    bytes32 internal constant MARKET_FRXUSDCRVUSD_USDC_ID =
        0xa67cfcdf2a2637c78fd6e1879e27448be7abe90c6ef1be4a1ca4337db886c8e3;

    // Curve pyUSD/crvUSD market https://app.morpho.org/ethereum/market/0x9ff17ee333e340b4f833ba0ba36899a44ea6808ea2d739928f80fec89cf7ba2e
    address internal constant MARKET_PYUSDCRVUSD_USDC_ORACLE = 0x22ec58046c98933bE51c1DF5C165Ae8cb2fc3B36;
    address internal constant MARKET_PYUSDCRVUSD_USDC_COLLATERAL = 0xC3361F107c0b82864D5B100A2f3C3E0a1a3586DA;
    bytes32 internal constant MARKET_PYUSDCRVUSD_USDC_ID =
        0x9ff17ee333e340b4f833ba0ba36899a44ea6808ea2d739928f80fec89cf7ba2e;

    ///////////////////////////////////////////////////////////////
    // --- FRXUSD VAULTS/MARKETS
    ///////////////////////////////////////////////////////////////

    address internal constant STAKEDAO_VAULT_FRXUSD_V1 = 0xB2376cC88EA47C80fFC3De60dAe8F2F48BC872a3;
    address internal constant STAKEDAO_VAULT_FRXUSD_V2 = 0xCE13e39534082FCF8f13F6D84e6D95414D14271e;

    // Curve frxUSD/crvUSD market https://app.morpho.org/ethereum/market/0x7629b62c42febfccd87a8eb76bd91587b33bbcd474cb79bc4964aeb0479e4e53
    address internal constant MARKET_FRXUSDCRVUSD_FRXUSD_ORACLE = 0xDE00641b654B5E6447D0277a8bEad00309Fc86c2;
    address internal constant MARKET_FRXUSDCRVUSD_FRXUSD_COLLATERAL = 0x61ec68a5a79905a82Bd594dC847E284Df17a8760;
    bytes32 internal constant MARKET_FRXUSDCRVUSD_FRXUSD_ID =
        0x7629b62c42febfccd87a8eb76bd91587b33bbcd474cb79bc4964aeb0479e4e53;

    // Curve frxUSD/msUSD market https://app.morpho.org/ethereum/market/0x24a1ac1fb21a206906af5acf2d65a6e6d9627823c195efef112d3a9b6cd5eab6
    address internal constant MARKET_FRXUSDMSUSD_FRXUSD_ORACLE = 0xC5860e9e6b6F6E9D79DCe5c5AB0F7A4b878Bd431;
    address internal constant MARKET_FRXUSDMSUSD_FRXUSD_COLLATERAL = 0x3B855AA8CC56a3cBd5dBb5456F5A13Ce86AA0fe8;
    bytes32 internal constant MARKET_FRXUSDMSUSD_FRXUSD_ID =
        0x24a1ac1fb21a206906af5acf2d65a6e6d9627823c195efef112d3a9b6cd5eab6;

    // Curve frxUSD/oUSD market https://app.morpho.org/ethereum/market/0xb7d1981ca0657c42bf003aca966f6a873ade2ae55d472d019a4ea03bc74f29f0
    address internal constant MARKET_FRXUSDOUSD_FRXUSD_ORACLE = 0xF0fC06217C5a728776AAc76F4bc5cf3112730960;
    address internal constant MARKET_FRXUSDOUSD_FRXUSD_COLLATERAL = 0x95B2b136eb0Bf075072D0c759e475453711A33f5;
    bytes32 internal constant MARKET_FRXUSDOUSD_FRXUSD_ID =
        0xb7d1981ca0657c42bf003aca966f6a873ade2ae55d472d019a4ea03bc74f29f0;

    // Curve frxUSD/avUSD market https://app.morpho.org/ethereum/market/0x3a7c4f7a5b837facbad5ca9313042d5864c4ef5dda582c5d7339dfd431f39dc1
    address internal constant MARKET_FRXUSDAVUSD_FRXUSD_ORACLE = 0x19747F93d0cd37FdF8bf52Bc158880888418316a;
    address internal constant MARKET_FRXUSDAVUSD_FRXUSD_COLLATERAL = 0x4926F23927fbABe8580c183E07E34D4B147EaFc0;
    bytes32 internal constant MARKET_FRXUSDAVUSD_FRXUSD_ID =
        0x3a7c4f7a5b837facbad5ca9313042d5864c4ef5dda582c5d7339dfd431f39dc1;

    // Curve frxUSD/sUSDS market https://app.morpho.org/ethereum/market/0x87e3786114cbe9d3fcace0eb4099fa70a4b916039db4a29626cae89147180ca3
    address internal constant MARKET_FRXUSDSUSDS_FRXUSD_ORACLE = 0xF694F0EE087d849DB66d14793f6508a794a02746;
    address internal constant MARKET_FRXUSDSUSDS_FRXUSD_COLLATERAL = 0xdA36Ab65d5Af53763CAcD63AE7D441932032326f;
    bytes32 internal constant MARKET_FRXUSDSUSDS_FRXUSD_ID =
        0x87e3786114cbe9d3fcace0eb4099fa70a4b916039db4a29626cae89147180ca3;

    ///////////////////////////////////////////////////////////////
    // --- PERIPHERY
    ///////////////////////////////////////////////////////////////
    address internal constant PUBLIC_FACTORY_MONOLITHIC = 0xf863337EE1a65Ec8c95392c8Aaa8eDEd86b7B80f;
    address internal constant LIQUIDATION_MODULE = 0x2e8328b978558FA01715F2220D07801DD0882621;
    address internal constant LEVERAGE_ROUTER = 0x07fa4Cca2A020fa9477eF7db5848bD976b64EeBC;
}

library Zap {
    address internal constant ENSO_ROUTER = 0xF75584eF6673aD213a685a1B58Cc0330B8eA22Cf;
}
