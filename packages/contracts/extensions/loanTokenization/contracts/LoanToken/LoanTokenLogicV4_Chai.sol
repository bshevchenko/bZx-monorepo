/**
 * Copyright 2017-2020, bZeroX, LLC. All Rights Reserved.
 * Licensed under the Apache License, Version 2.0.
 */

pragma solidity 0.5.8;
pragma experimental ABIEncoderV2;

import "./AdvancedToken.sol";
import "../shared/OracleNotifierInterface.sol";


interface IBZx {
    function takeOrderFromiToken(
        bytes32 loanOrderHash, // existing loan order hash
        address[4] calldata sentAddresses,
            // trader: borrower/trader
            // collateralTokenAddress: collateral token
            // tradeTokenAddress: trade token
            // receiver: receiver of funds (address(0) assumes trader address)
        uint256[7] calldata sentAmounts,
            // newInterestRate: new loan interest rate
            // newLoanAmount: new loan size (principal from lender)
            // interestInitialAmount: interestAmount sent to determine initial loan length (this is included in one of the below)
            // loanTokenSent: loanTokenAmount + interestAmount + any extra
            // collateralTokenSent: collateralAmountRequired + any extra
            // tradeTokenSent: tradeTokenAmount (optional)
            // withdrawalAmount: Actual amount sent to borrower (can't exceed newLoanAmount)
        bytes calldata loanDataBytes)
        external
        payable
        returns (uint256);

    function payInterestForOracle(
        address oracleAddress,
        address interestTokenAddress)
        external
        returns (uint256);

    function getLenderInterestForOracle(
        address lender,
        address oracleAddress,
        address interestTokenAddress)
        external
        view
        returns (
            uint256 interestPaid,
            uint256 interestPaidDate,
            uint256 interestOwedPerDay,
            uint256 interestUnPaid);

    function oracleAddresses(
        address oracleAddress)
        external
        view
        returns (address);

    function getRequiredCollateral(
        address loanTokenAddress,
        address collateralTokenAddress,
        address oracleAddress,
        uint256 newLoanAmount,
        uint256 marginAmount)
        external
        view
        returns (uint256 collateralTokenAmount);

    function getBorrowAmount(
        address loanTokenAddress,
        address collateralTokenAddress,
        address oracleAddress,
        uint256 collateralTokenAmount,
        uint256 marginAmount)
        external
        view
        returns (uint256 borrowAmount);
}

interface IBZxOracle {
    function getTradeData(
        address sourceTokenAddress,
        address destTokenAddress,
        uint256 sourceTokenAmount)
        external
        view
        returns (
            uint256 sourceToDestRate,
            uint256 sourceToDestPrecision,
            uint256 destTokenAmount
        );
}

interface iChai {
    function move(
        address src,
        address dst,
        uint256 wad)
        external
        returns (bool);

    function join(
        address dst, 
        uint256 wad)
        external;

    function draw(
        address src,
        uint256 wad)
        external;

    function balanceOf(
        address _who)
        external
        view
        returns (uint256);
}

interface iPot {
    function dsr()
        external
        view
        returns (uint256);

    function chi()
        external
        view
        returns (uint256);

    function rho()
        external
        view
        returns (uint256);
}

contract LoanTokenLogicV4_Chai is AdvancedToken, OracleNotifierInterface {
    using SafeMath for uint256;

    address internal target_;

    uint256 constant RAY = 10 ** 27;

    address internal constant arbitraryCaller = 0x4c67b3dB1d4474c0EBb2DB8BeC4e345526d9E2fd;

    // Mainnet
    iChai public constant chai = iChai(0x06AF07097C9Eeb7fD685c692751D5C66dB49c215);
    iPot public constant pot = iPot(0x197E90f9FAD81970bA7976f33CbD77088E5D7cf7);
    ERC20 public constant dai = ERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    // Kovan
    /*iChai public constant chai = iChai(0x71DD45d9579A499B58aa85F50E5E3B241Ca2d10d);
    iPot public constant pot = iPot(0xEA190DBDC7adF265260ec4dA6e9675Fd4f5A78bb);
    ERC20 public constant dai = ERC20(0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa);*/

    modifier onlyOracle() {
        require(msg.sender == IBZx(bZxContract).oracleAddresses(bZxOracle), "1");
        _;
    }


    function()
        external
    {}


    /* Public functions */

    function mintWithChai(
        address receiver,
        uint256 depositAmount)
        external
        nonReentrant
        returns (uint256 mintAmount)
    {
        return _mintToken(
            receiver,
            depositAmount,
            true // withChai
        );
    }

    function mint(
        address receiver,
        uint256 depositAmount)
        external
        nonReentrant
        returns (uint256 mintAmount)
    {
        return _mintToken(
            receiver,
            depositAmount,
            false // withChai
        );
    }

    function burnToChai(
        address receiver,
        uint256 burnAmount)
        external
        nonReentrant
        returns (uint256 chaiAmountPaid)
    {
        return _burnToken(
            burnAmount,
            receiver,
            true // toChai
        );
    }

    function burn(
        address receiver,
        uint256 burnAmount)
        external
        nonReentrant
        returns (uint256 loanAmountPaid)
    {
        return _burnToken(
            burnAmount,
            receiver,
            false // toChai
        );
    }

    function flashBorrowToken(
        uint256 borrowAmount,
        address borrower,
        address target,
        string calldata signature,
        bytes calldata data)
        external
        payable
        nonReentrant
        returns (bytes memory)
    {
        _settleInterest();

        ERC20 _dai;
        if (borrowAmount != 0) {
            _dai = _dsrWithdraw(borrowAmount);
        }

        uint256 beforeEtherBalance = address(this).balance.sub(msg.value);
        uint256 beforeAssetsBalance = _underlyingBalance()
            .add(totalAssetBorrow);
        require(beforeAssetsBalance != 0, "38");

        if (borrowAmount != 0) {
            require(_dai.transfer(
                borrower,
                borrowAmount
            ), "39");
        }

        bytes memory callData;
        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        burntTokenReserved = beforeAssetsBalance;

        (bool success, bytes memory returnData) = arbitraryCaller.call.value(msg.value)(
            abi.encodeWithSelector(
                0xde064e0d, // sendCall(address,bytes)
                target,
                callData
            )
        );
        require(success, "call failed");

        burntTokenReserved = 0;

        require(
            address(this).balance >= beforeEtherBalance &&
            _underlyingBalance()
                .add(totalAssetBorrow) >= beforeAssetsBalance,
            "40"
        );

        _dsrDeposit();

        return returnData;
    }

    function borrowTokenFromDeposit(
        uint256 borrowAmount,
        uint256 leverageAmount,
        uint256 initialLoanDuration,    // duration in seconds
        uint256 collateralTokenSent,    // set to 0 if sending ETH
        address borrower,
        address receiver,
        address collateralTokenAddress, // address(0) means ETH and ETH must be sent with the call
        bytes memory /*loanDataBytes*/) // arbitrary order data
        public
        payable
        returns (bytes32 loanOrderHash)
    {
        require(
            ((msg.value == 0 && collateralTokenAddress != address(0) && collateralTokenSent != 0) ||
            (msg.value != 0 && (collateralTokenAddress == address(0) || collateralTokenAddress == wethContract) && collateralTokenSent == 0)),
            "6"
        );

        if (msg.value != 0) {
            collateralTokenAddress = wethContract;
            collateralTokenSent = msg.value;
        }

        uint256 _borrowAmount = borrowAmount;

        leverageAmount = uint256(keccak256(abi.encodePacked(leverageAmount,collateralTokenAddress)));
        loanOrderHash = loanOrderHashes[leverageAmount];
        require(loanOrderHash != 0, "7");

        _settleInterest();

        uint256[7] memory sentAmounts;

        LoanData memory loanOrder = loanOrderData[loanOrderHash];
        bool useFixedInterestModel = loanOrder.maxDurationUnixTimestampSec == 0;

        if (_borrowAmount == 0) {
            _borrowAmount = _getBorrowAmountForDeposit(
                collateralTokenSent,
                leverageAmount,
                initialLoanDuration,
                collateralTokenAddress
            );
            require(_borrowAmount != 0, "35");

            // withdrawalAmount
            sentAmounts[6] = _borrowAmount;
        } else {
            // withdrawalAmount
            sentAmounts[6] = _borrowAmount;
        }

        // interestRate, interestInitialAmount, borrowAmount (newBorrowAmount)
        (sentAmounts[0], sentAmounts[2], _borrowAmount) = _getInterestRateAndAmount(
            _borrowAmount,
            _totalAssetSupply(0), // interest is settled above
            initialLoanDuration,
            useFixedInterestModel
        );

        sentAmounts[6] = _borrowTokenAndUseFinal(
            loanOrderHash,
            [
                borrower,
                collateralTokenAddress,
                address(0), // tradeTokenAddress
                receiver
            ],
            [
                sentAmounts[0],         // interestRate
                _borrowAmount,
                sentAmounts[2],         // interestInitialAmount
                0,                      // loanTokenSent
                collateralTokenSent,
                0,                      // tradeTokenSent
                sentAmounts[6]          // withdrawalAmount
            ],
            ""                          // loanDataBytes
        );
        require(sentAmounts[6] == _borrowAmount, "8");

        _dsrDeposit();
    }

    // Called to borrow token for withdrawal or trade
    // borrowAmount: loan amount to borrow
    // leverageAmount: signals the amount of initial margin we will collect
    //   Please reference the docs for supported values.
    //   Example: 2000000000000000000 -> 150% initial margin
    //            2000000000000000028 -> 150% initial margin, 28-day fixed-term
    // interestInitialAmount: This value will indicate the initial duration of the loan
    //   This is ignored if the loan order has a fixed-term
    // loanTokenSent: loan token sent (interestAmount + extra)
    // collateralTokenSent: collateral token sent
    // tradeTokenSent: trade token sent
    // borrower: the address the loan will be assigned to (this address can be different than msg.sender)
    //    Collateral and interest for loan will be withdrawn from msg.sender
    // receiver: the address that receives the funds (address(0) assumes borrower address)
    // collateralTokenAddress: The token to collateralize the loan in
    // tradeTokenAddress: The borrowed token will be swap for this token to start a leveraged trade
    //    If the borrower wished to instead withdraw the borrowed token to their wallet, set this to address(0)
    //    If set to address(0), initial collateral required will equal initial margin percent + 100%
    // returns loanOrderHash for the base protocol loan
    function borrowTokenAndUse(
        uint256 borrowAmount,
        uint256 leverageAmount,
        uint256 interestInitialAmount,
        uint256 loanTokenSent,
        uint256 collateralTokenSent,
        uint256 tradeTokenSent,
        address borrower,
        address receiver,
        address collateralTokenAddress,
        address tradeTokenAddress,
        bytes memory /*loanDataBytes*/)
        public
        //payable
        returns (bytes32 loanOrderHash)
    {
        address[4] memory sentAddresses;
        sentAddresses[0] = borrower;
        sentAddresses[1] = collateralTokenAddress;
        sentAddresses[2] = tradeTokenAddress;
        sentAddresses[3] = receiver;

        uint256[7] memory sentAmounts;
        //sentAmounts[0] = 0;  // interestRate (found later)
        sentAmounts[1] = borrowAmount;
        sentAmounts[2] = interestInitialAmount;
        sentAmounts[3] = loanTokenSent;
        sentAmounts[4] = collateralTokenSent;
        sentAmounts[5] = tradeTokenSent;
        sentAmounts[6] = sentAmounts[1];

        require(sentAddresses[1] != address(0) &&
            (sentAddresses[2] == address(0) ||
                sentAddresses[2] != address(_getDai())),
            "9"
        );

        loanOrderHash = _borrowTokenAndUse(
            uint256(keccak256(abi.encodePacked(leverageAmount,sentAddresses[1]))),
            sentAddresses,
            sentAmounts,
            false, // amountIsADeposit
            ""      // loanDataBytes
        );
    }

    // Called by pTokens to borrow and immediately get into a positions
    // Other traders can call this, but it's recommended to instead use borrowTokenAndUse(...) instead
    // assumption: depositAmount is collateral + interest deposit and will be denominated in deposit token
    // assumption: loan token and interest token are the same
    // returns loanOrderHash for the base protocol loan
    function marginTradeFromDeposit(
        uint256 depositAmount,
        uint256 leverageAmount,
        uint256 loanTokenSent,
        uint256 collateralTokenSent,
        uint256 tradeTokenSent,
        address trader,
        address depositTokenAddress,
        address collateralTokenAddress,
        address tradeTokenAddress,
        bytes memory loanDataBytes)
        public
        payable
        returns (bytes32 loanOrderHash)
    {
        address _daiAddress = address(_getDai());
        require(tradeTokenAddress != address(0) &&
            tradeTokenAddress != _daiAddress,
            "10"
        );

        uint256 amount = depositAmount;
        // To calculate borrow amount and interest owed to lender we need deposit amount to be represented as loan token
        if (depositTokenAddress == tradeTokenAddress) {
            (,,amount) = IBZxOracle(bZxOracle).getTradeData(
                tradeTokenAddress,
                _daiAddress,
                amount
            );
        } else if (depositTokenAddress != _daiAddress) {
            // depositTokenAddress can only be tradeTokenAddress or loanTokenAddress
            revert("11");
        }

        loanOrderHash = _borrowTokenAndUse(
            leverageAmount,
            [
                trader,
                collateralTokenAddress,     // collateralTokenAddress
                tradeTokenAddress,          // tradeTokenAddress
                trader                      // receiver
            ],
            [
                0,                      // interestRate (found later)
                amount,                 // amount of deposit
                0,                      // interestInitialAmount (interest is calculated based on fixed-term loan)
                loanTokenSent,
                collateralTokenSent,
                tradeTokenSent,
                0
            ],
            true,                       // amountIsADeposit
            loanDataBytes
        );
    }

    function transfer(
        address _to,
        uint256 _value)
        public
        returns (bool)
    {
        require(_value <= balances[msg.sender] &&
            _to != address(0),
            "13"
        );

        balances[msg.sender] = balances[msg.sender].sub(_value);
        balances[_to] = balances[_to].add(_value);

        // handle checkpoint update
        uint256 currentPrice = tokenPrice();
        if (balances[msg.sender] != 0) {
            checkpointPrices_[msg.sender] = currentPrice;
        } else {
            checkpointPrices_[msg.sender] = 0;
        }
        if (balances[_to] != 0) {
            checkpointPrices_[_to] = currentPrice;
        } else {
            checkpointPrices_[_to] = 0;
        }

        emit Transfer(msg.sender, _to, _value);
        return true;
    }

    function transferFrom(
        address _from,
        address _to,
        uint256 _value)
        public
        returns (bool)
    {
        uint256 allowanceAmount = allowed[_from][msg.sender];
        require(_value <= balances[_from] &&
            _value <= allowanceAmount &&
            _to != address(0),
            "14"
        );

        balances[_from] = balances[_from].sub(_value);
        balances[_to] = balances[_to].add(_value);
        if (allowanceAmount < MAX_UINT) {
            allowed[_from][msg.sender] = allowanceAmount.sub(_value);
        }

        // handle checkpoint update
        uint256 currentPrice = tokenPrice();
        if (balances[_from] != 0) {
            checkpointPrices_[_from] = currentPrice;
        } else {
            checkpointPrices_[_from] = 0;
        }
        if (balances[_to] != 0) {
            checkpointPrices_[_to] = currentPrice;
        } else {
            checkpointPrices_[_to] = 0;
        }

        emit Transfer(_from, _to, _value);
        return true;
    }


    /* Public View functions */

    // the current Maker DSR normalized to APR
    function dsr()
        public
        view
        returns (uint256)
    {
        return _getPot().dsr()
            .sub(RAY)
            .mul(31536000) // seconds in a year
            .div(10**7);
    }

    // daiAmount = chaiAmount * chaiPrice
    function chaiPrice()
        public
        view
        returns (uint256)
    {
        return _rChaiPrice()
            .div(10**9);
    }

    function tokenPrice()
        public
        view
        returns (uint256 price)
    {
        uint256 interestUnPaid;
        if (lastSettleTime_ != block.timestamp) {
            (,interestUnPaid) = _getAllInterest();
        }

        return _tokenPrice(_totalAssetSupply(interestUnPaid));
    }

    function checkpointPrice(
        address _user)
        public
        view
        returns (uint256 price)
    {
        return checkpointPrices_[_user];
    }

    function marketLiquidity()
        public
        view
        returns (uint256)
    {
        uint256 totalSupply = totalAssetSupply();
        if (totalSupply > totalAssetBorrow) {
            return totalSupply.sub(totalAssetBorrow);
        }
    }

    function protocolInterestRate()
        public
        view
        returns (uint256)
    {
        return _protocolInterestRate(totalAssetBorrow);
    }

    // the minimum rate the next base protocol borrower will receive for variable-rate loans
    function borrowInterestRate()
        public
        view
        returns (uint256)
    {
        return _nextBorrowInterestRate(
            0,              // borrowAmount
            false           // useFixedInterestModel
        );
    }

    function nextBorrowInterestRate(
        uint256 borrowAmount)
        public
        view
        returns (uint256)
    {
        return _nextBorrowInterestRate(
            borrowAmount,
            false           // useFixedInterestModel
        );
    }

    function nextBorrowInterestRateWithOption(
        uint256 borrowAmount,
        bool useFixedInterestModel)
        public
        view
        returns (uint256)
    {
        return _nextBorrowInterestRate(
            borrowAmount,
            useFixedInterestModel
        );
    }

    // the average interest that borrowers are currently paying for open loans
    function avgBorrowInterestRate()
        public
        view
        returns (uint256)
    {
        uint256 assetBorrow = totalAssetBorrow;
        if (assetBorrow != 0) {
            return _protocolInterestRate(assetBorrow)
                .mul(checkpointSupply)
                .div(totalAssetSupply());
        } else {
            return _getLowUtilBaseRate();
        }
    }

    // interest that lenders are currently receiving when supplying to the pool
    function supplyInterestRate()
        public
        view
        returns (uint256)
    {
        return totalSupplyInterestRate(totalAssetSupply());
    }

    function nextSupplyInterestRate(
        uint256 supplyAmount)
        public
        view
        returns (uint256)
    {
        return totalSupplyInterestRate(totalAssetSupply().add(supplyAmount));
    }

    function totalSupplyInterestRate(
        uint256 assetSupply)
        public
        view
        returns (uint256)
    {
        uint256 assetBorrow = totalAssetBorrow;
        if (assetBorrow != 0) {
            return _supplyInterestRate(
                assetBorrow,
                assetSupply
            );
        } else {
            return dsr();
        }
    }

    function totalAssetSupply()
        public
        view
        returns (uint256)
    {
        uint256 interestUnPaid;
        if (lastSettleTime_ != block.timestamp) {
            (,interestUnPaid) = _getAllInterest();
        }

        return _totalAssetSupply(interestUnPaid);
    }

    function getMaxEscrowAmount(
        uint256 leverageAmount)
        public
        view
        returns (uint256)
    {
        LoanData memory loanData = loanOrderData[loanOrderHashes[leverageAmount]];
        if (loanData.initialMarginAmount == 0)
            return 0;

        return marketLiquidity()
            .mul(loanData.initialMarginAmount)
            .div(_adjustValue(
                10**20, // maximum possible interest (100%)
                loanData.maxDurationUnixTimestampSec,
                loanData.initialMarginAmount));
    }

    function getLeverageList()
        public
        view
        returns (uint256[] memory)
    {
        return leverageList;
    }

    function getLoanData(
        bytes32 loanOrderHash)
        public
        view
        returns (LoanData memory)
    {
        return loanOrderData[loanOrderHash];
    }

    // returns the user's balance of underlying token
    function assetBalanceOf(
        address _owner)
        public
        view
        returns (uint256)
    {
        return balanceOf(_owner)
            .mul(tokenPrice())
            .div(10**18);
    }

    function getDepositAmountForBorrow(
        uint256 borrowAmount,
        uint256 leverageAmount,             // use 2000000000000000000 for 150% initial margin
        uint256 initialLoanDuration,        // duration in seconds
        address collateralTokenAddress)     // address(0) means ETH
        public
        view
        returns (uint256 depositAmount)
    {
        if (borrowAmount != 0) {
            leverageAmount = uint256(keccak256(abi.encodePacked(leverageAmount,collateralTokenAddress)));
            LoanData memory loanOrder = loanOrderData[loanOrderHashes[leverageAmount]];
            uint256 marginAmount = loanOrder.initialMarginAmount
                .add(10**20); // adjust for over-collateralized loan
                //.add(loanOrder.marginPremiumAmount);

            // adjust value since interest is also borrowed
            borrowAmount = borrowAmount
                .mul(_getTargetNextRateMultiplierValue(initialLoanDuration))
                .div(10**22);

            if (borrowAmount <= _underlyingBalance()) {
                return IBZx(bZxContract).getRequiredCollateral(
                    address(_getDai()),
                    collateralTokenAddress != address(0) ? collateralTokenAddress : wethContract,
                    bZxOracle,
                    borrowAmount,
                    marginAmount
                ).add(10); // add some dust to ensure enough is borrowed later
            }
        }
    }

    function getBorrowAmountForDeposit(
        uint256 depositAmount,
        uint256 leverageAmount,             // use 2000000000000000000 for 150% initial margin
        uint256 initialLoanDuration,        // duration in seconds
        address collateralTokenAddress)     // address(0) means ETH
        public
        view
        returns (uint256 borrowAmount)
    {
        leverageAmount = uint256(keccak256(abi.encodePacked(leverageAmount,collateralTokenAddress)));
        borrowAmount = _getBorrowAmountForDeposit(
            depositAmount,
            leverageAmount,
            initialLoanDuration,
            collateralTokenAddress
        );
    }

    // can safely be called by anyone at anytime
    function setupChai()
        public
    {
        _getDai().approve(address(_getChai()), MAX_UINT);
        _dsrDeposit();
    }


    /* Internal functions */

    function _mintToken(
        address receiver,
        uint256 depositAmount,
        bool withChai)
        internal
        returns (uint256 mintAmount)
    {
        require (depositAmount != 0, "17");

        _settleInterest();

        uint256 currentPrice = _tokenPrice(_totalAssetSupply(0));
        uint256 currentChaiPrice;
        ERC20 inAsset;

        if (withChai) {
            inAsset = ERC20(address(_getChai()));
            currentChaiPrice = chaiPrice();
        } else {
            inAsset = ERC20(address(_getDai()));
        }

        require(inAsset.transferFrom(
            msg.sender,
            address(this),
            depositAmount
        ), "18");

        _dsrDeposit();

        if (withChai) {
            // convert to Dai
            depositAmount = depositAmount
                .mul(currentChaiPrice)
                .div(10**18);
        }

        mintAmount = depositAmount
            .mul(10**18)
            .div(currentPrice);

        _mint(receiver, mintAmount, depositAmount, currentPrice);

        checkpointPrices_[receiver] = currentPrice;
    }

    function _burnToken(
        uint256 burnAmount,
        address receiver,
        bool toChai)
        internal
        returns (uint256 amountPaid)
    {
        require(burnAmount != 0, "19");

        if (burnAmount > balanceOf(msg.sender)) {
            burnAmount = balanceOf(msg.sender);
        }

        _settleInterest();

        uint256 currentPrice = _tokenPrice(_totalAssetSupply(0));

        uint256 loanAmountOwed = burnAmount
            .mul(currentPrice)
            .div(10**18);

        amountPaid = loanAmountOwed;

        bool success;
        if (toChai) {
            _dsrDeposit();
            
            iChai _chai = _getChai();
            uint256 chaiBalance = _chai.balanceOf(address(this));
            
            success = _chai.move(
                address(this),
                msg.sender,
                amountPaid
            );

            // get Chai amount withdrawn
            amountPaid = chaiBalance
                .sub(_chai.balanceOf(address(this)));
        } else {
            success = _dsrWithdraw(amountPaid).transfer(
                receiver,
                amountPaid
            );

            _dsrDeposit();
        }
        require (success, "37"); // free liquidity of DAI/CHAI insufficient

        _burn(msg.sender, burnAmount, loanAmountOwed, currentPrice);

        if (balances[msg.sender] != 0) {
            checkpointPrices_[msg.sender] = currentPrice;
        } else {
            checkpointPrices_[msg.sender] = 0;
        }
    }

    function _settleInterest()
        internal
    {
        if (lastSettleTime_ != block.timestamp) {
            IBZx(bZxContract).payInterestForOracle(
                bZxOracle, // (leave as original value)
                address(_getDai()) // same as interestTokenAddress
            );

            lastSettleTime_ = block.timestamp;
        }
    }

    function _getBorrowAmountForDeposit(
        uint256 depositAmount,
        uint256 leverageAmount,             // use 2000000000000000000 for 150% initial margin
        uint256 initialLoanDuration,        // duration in seconds
        address collateralTokenAddress)     // address(0) means ETH
        internal
        view
        returns (uint256 borrowAmount)
    {
        if (depositAmount != 0) {
            LoanData memory loanOrder = loanOrderData[loanOrderHashes[leverageAmount]];
            uint256 marginAmount = loanOrder.initialMarginAmount
                .add(10**20); // adjust for over-collateralized loan
                //.add(loanOrder.marginPremiumAmount);

            borrowAmount = IBZx(bZxContract).getBorrowAmount(
                address(_getDai()),
                collateralTokenAddress != address(0) ? collateralTokenAddress : wethContract,
                bZxOracle,
                depositAmount,
                marginAmount
            );

            // adjust value since interest is also borrowed
            borrowAmount = borrowAmount
                .mul(10**22)
                .div(_getTargetNextRateMultiplierValue(initialLoanDuration));

            if (borrowAmount > _underlyingBalance()) {
                borrowAmount = 0;
            }
        }
    }

    function _getTargetNextRateMultiplierValue(
        uint256 initialLoanDuration)
        internal
        view
        returns (uint256)
    {
        return rateMultiplier
            .mul(80 ether)
            .div(10**20)
            .add(baseRate)
            .mul(initialLoanDuration)
            .div(315360) // 365 * 86400 / 100
            .add(10**22);
    }

    function _getInterestRateAndAmount(
        uint256 borrowAmount,
        uint256 assetSupply,
        uint256 initialLoanDuration,        // duration in seconds
        bool useFixedInterestModel)         // False=variable interest, True=fixed interest
        internal
        view
        returns (uint256 interestRate, uint256 interestInitialAmount, uint256 newBorrowAmount)
    {
        (,interestInitialAmount) = _getInterestRateAndAmount2(
            borrowAmount,
            assetSupply,
            initialLoanDuration,
            useFixedInterestModel
        );

        (interestRate, interestInitialAmount) = _getInterestRateAndAmount2(
            borrowAmount
                .add(interestInitialAmount),
            assetSupply,
            initialLoanDuration,
            useFixedInterestModel
        );

        newBorrowAmount = borrowAmount
            .add(interestInitialAmount);
    }

    function _getInterestRateAndAmount2(
        uint256 borrowAmount,
        uint256 assetSupply,
        uint256 initialLoanDuration,
        bool useFixedInterestModel)
        internal
        view
        returns (uint256 interestRate, uint256 interestInitialAmount)
    {
        interestRate = _nextBorrowInterestRate2(
            borrowAmount,
            assetSupply,
            useFixedInterestModel
        );

        // initial interestInitialAmount
        interestInitialAmount = borrowAmount
            .mul(interestRate)
            .mul(initialLoanDuration)
            .div(31536000 * 10**20); // 365 * 86400 * 10**20
    }

    function _borrowTokenAndUse(
        uint256 leverageAmount,
        address[4] memory sentAddresses,
        uint256[7] memory sentAmounts,
        bool amountIsADeposit,
        bytes memory loanDataBytes)
        internal
        returns (bytes32 loanOrderHash)
    {
        require(sentAmounts[1] != 0, "21"); // amount

        loanOrderHash = loanOrderHashes[leverageAmount];
        require(loanOrderHash != 0, "22");

        _settleInterest();

        LoanData memory loanOrder = loanOrderData[loanOrderHash];
        bool useFixedInterestModel = loanOrder.maxDurationUnixTimestampSec == 0;
        //sentAmounts[7] = loanOrder.marginPremiumAmount;

        if (amountIsADeposit) {
            (sentAmounts[1], sentAmounts[0]) = _getBorrowAmountAndRate( // borrowAmount, interestRate
                loanOrderHash,
                sentAmounts[1], // amount
                useFixedInterestModel
            );

            // update for borrowAmount
            sentAmounts[6] = sentAmounts[1]; // borrowAmount
        } else {
            // amount is borrow amount
            sentAmounts[0] = _nextBorrowInterestRate2( // interestRate
                sentAmounts[1], // amount
                _totalAssetSupply(0),
                useFixedInterestModel
            );
        }

        if (sentAddresses[2] == address(0)) { // tradeTokenAddress
            // tradeTokenSent is ignored if trade token isn't specified
            sentAmounts[5] = 0;
        }

        uint256 borrowAmount = _borrowTokenAndUseFinal(
            loanOrderHash,
            sentAddresses,
            sentAmounts,
            loanDataBytes
        );
        require(borrowAmount == sentAmounts[1], "23");

        _dsrDeposit();
    }

    // returns borrowAmount
    function _borrowTokenAndUseFinal(
        bytes32 loanOrderHash,
        address[4] memory sentAddresses,
        uint256[7] memory sentAmounts,
        bytes memory loanDataBytes)
        internal
        returns (uint256)
    {
        require (sentAmounts[1] <= _underlyingBalance() && // borrowAmount
            sentAddresses[0] != address(0), // borrower
            "24"
        );

        if (sentAddresses[3] == address(0)) {
            sentAddresses[3] = sentAddresses[0]; // receiver = borrower
        }

        // handle transfers prior to adding borrowAmount to loanTokenSent
        _verifyTransfers(
            sentAddresses,
            sentAmounts
        );

        // adding the loan token amount from the lender to loanTokenSent
        sentAmounts[3] = sentAmounts[3]
            .add(sentAmounts[1]); // borrowAmount

        uint256 msgValue;
        if (msg.value != 0) {
            msgValue = address(this).balance;
            if (msgValue > msg.value) {
                msgValue = msg.value;
            }
        }
        sentAmounts[1] = IBZx(bZxContract).takeOrderFromiToken.value(msgValue)( // borrowAmount
            loanOrderHash,
            sentAddresses,
            sentAmounts,
            loanDataBytes
        );
        require (sentAmounts[1] != 0, "25");

        // update total borrowed amount outstanding in loans
        totalAssetBorrow = totalAssetBorrow
            .add(sentAmounts[1]); // borrowAmount

        // checkpoint supply since the base protocol borrow stats have changed
        checkpointSupply = _totalAssetSupply(0);

        emit Borrow(
            sentAddresses[0],               // borrower
            sentAmounts[1],                 // borrowAmount
            sentAmounts[0],                 // interestRate
            sentAddresses[1],               // collateralTokenAddress
            sentAddresses[2],               // tradeTokenAddress
            sentAddresses[2] == address(0)  // withdrawOnOpen
        );

        return sentAmounts[1]; // borrowAmount;
    }

    // sentAddresses[0]: borrower
    // sentAddresses[1]: collateralTokenAddress
    // sentAddresses[2]: tradeTokenAddress
    // sentAddresses[3]: receiver
    // sentAmounts[0]: interestRate
    // sentAmounts[1]: borrowAmount
    // sentAmounts[2]: interestInitialAmount
    // sentAmounts[3]: loanTokenSent
    // sentAmounts[4]: collateralTokenSent
    // sentAmounts[5]: tradeTokenSent
    // sentAmounts[6]: withdrawalAmount
    function _verifyTransfers(
        address[4] memory sentAddresses,
        uint256[7] memory sentAmounts)
        internal
    {
        address collateralTokenAddress = sentAddresses[1];
        address tradeTokenAddress = sentAddresses[2];
        address receiver = sentAddresses[3];
        uint256 borrowAmount = sentAmounts[1];
        uint256 loanTokenSent = sentAmounts[3];
        uint256 collateralTokenSent = sentAmounts[4];
        uint256 tradeTokenSent = sentAmounts[5];
        uint256 withdrawalAmount = sentAmounts[6];

        ERC20 _dai = _dsrWithdraw(borrowAmount);

        bool success;
        if (tradeTokenAddress == address(0)) { // withdrawOnOpen == true
            success = _dai.transfer(
                receiver,
                withdrawalAmount
            );

            if (success && borrowAmount > withdrawalAmount) {
                success = _dai.transfer(
                    bZxVault,
                    borrowAmount - withdrawalAmount
                );
            }
        } else {
            success = _dai.transfer(
                bZxVault,
                borrowAmount
            );
        }
        require(success, "26");

        success = false;
        if (collateralTokenSent != 0) {
            if (collateralTokenAddress == wethContract && msg.value != 0 && collateralTokenSent == msg.value) {
                WETHInterface(wethContract).deposit.value(collateralTokenSent)();
                success = ERC20(collateralTokenAddress).transfer(
                    bZxVault,
                    collateralTokenSent
                );
            } else {
                if (collateralTokenAddress == address(_dai)) {
                    loanTokenSent = loanTokenSent.add(collateralTokenSent);
                    success = true;
                } else if (collateralTokenAddress == tradeTokenAddress) {
                    tradeTokenSent = tradeTokenSent.add(collateralTokenSent);
                    success = true;
                } else {
                    success = ERC20(collateralTokenAddress).transferFrom(
                        msg.sender,
                        bZxVault,
                        collateralTokenSent
                    );
                }
            }
            require(success, "27");
        }

        if (loanTokenSent != 0) {
            if (address(_dai) == tradeTokenAddress) {
                tradeTokenSent = tradeTokenSent.add(loanTokenSent);
            } else {
                require(_dai.transferFrom(
                    msg.sender,
                    bZxVault,
                    loanTokenSent
                ), "31");
            }
        }

        if (tradeTokenSent != 0) {
            require(ERC20(tradeTokenAddress).transferFrom(
                msg.sender,
                bZxVault,
                tradeTokenSent
            ), "32");
        }
    }

    function _rChaiPrice()
        internal
        view
        returns (uint256)
    {
        iPot _pot = _getPot();

        uint256 rho = _pot.rho();
        uint256 chi = _pot.chi();
        if (now > rho) {
            chi = rmul(rpow(_pot.dsr(), now - rho, RAY), chi);
        }

        return chi;
    }

    function _dsrDeposit()
        internal
    {
        uint256 localBalance = _getDai().balanceOf(address(this));
        if (localBalance != 0) {
            _getChai().join(
                address(this),
                localBalance
            );
        }
    }

    function _dsrWithdraw(
        uint256 _value)
        internal
        returns (ERC20 _dai)
    {
        _dai = _getDai();
        uint256 localBalance = _dai.balanceOf(address(this));
        if (_value > localBalance) {
            _getChai().draw(
                address(this),
                _value - localBalance
            );
        }
    }

    function _underlyingBalance()
        internal
        view
        returns (uint256)
    {
        return rmul(
            _getChai().balanceOf(address(this)),
            _rChaiPrice())
            .add(_getDai().balanceOf(address(this)));
    }

    /* Internal View functions */

    function _tokenPrice(
        uint256 assetSupply)
        internal
        view
        returns (uint256)
    {
        uint256 totalTokenSupply = totalSupply_;

        return totalTokenSupply != 0 ?
            assetSupply
                .mul(10**18)
                .div(totalTokenSupply) : initialPrice;
    }

    function _protocolInterestRate(
        uint256 assetBorrow)
        internal
        view
        returns (uint256)
    {
        if (assetBorrow != 0) {
            (uint256 interestOwedPerDay,) = _getAllInterest();
            return interestOwedPerDay
                .mul(10**20)
                .div(assetBorrow)
                .mul(365);
        }
    }

    // next supply interest adjustment
    function _supplyInterestRate(
        uint256 assetBorrow,
        uint256 assetSupply)
        public
        view
        returns (uint256)
    {
        uint256 _dsr = dsr();
        if (assetBorrow != 0 && assetSupply >= assetBorrow) {
            uint256 localBalance = _getDai().balanceOf(address(this));

            uint256 _utilRate = _utilizationRate(
                assetBorrow,
                assetSupply
                    .sub(localBalance) // DAI not DSR'ed can't be counted
            );
            _dsr = _dsr
                .mul(SafeMath.sub(100 ether, _utilRate));

            if (localBalance != 0) {
                _utilRate = _utilizationRate(
                    assetBorrow,
                    assetSupply
                );
            }
            return _protocolInterestRate(assetBorrow)
                .mul(_utilRate)
                .add(_dsr)
                .div(10**20);
        } else {
            return _dsr;
        }
    }

    function _nextBorrowInterestRate(
        uint256 borrowAmount,
        bool useFixedInterestModel)
        internal
        view
        returns (uint256)
    {
        uint256 interestUnPaid;
        if (borrowAmount != 0) {
            if (lastSettleTime_ != block.timestamp) {
                (,interestUnPaid) = _getAllInterest();
            }

            uint256 balance = _underlyingBalance()
                .add(interestUnPaid);
            if (borrowAmount > balance) {
                borrowAmount = balance;
            }
        }

        return _nextBorrowInterestRate2(
            borrowAmount,
            _totalAssetSupply(interestUnPaid),
            useFixedInterestModel
        );
    }

    function _nextBorrowInterestRate2(
        uint256 newBorrowAmount,
        uint256 assetSupply,
        bool useFixedInterestModel)
        internal
        view
        returns (uint256 nextRate)
    {
        uint256 utilRate = _utilizationRate(
            totalAssetBorrow.add(newBorrowAmount),
            assetSupply
        );

        uint256 minRate;
        uint256 maxRate;
        uint256 thisBaseRate;
        uint256 thisRateMultiplier;

        if (useFixedInterestModel) {
            if (utilRate < 80 ether) {
                // target 80% utilization when loan is fixed-rate and utilization is under 80%
                utilRate = 80 ether;
            }

            //keccak256("iToken_FixedInterestBaseRate")
            //keccak256("iToken_FixedInterestRateMultiplier")
            assembly {
                thisBaseRate := sload(0x185a40c6b6d3f849f72c71ea950323d21149c27a9d90f7dc5e5ea2d332edcf7f)
                thisRateMultiplier := sload(0x9ff54bc0049f5eab56ca7cd14591be3f7ed6355b856d01e3770305c74a004ea2)
            }
        } else if (utilRate < 50 ether) {
            thisBaseRate = _getLowUtilBaseRate();

            //keccak256("iToken_LowUtilRateMultiplier")
            assembly {
                thisRateMultiplier := sload(0x2b4858b1bc9e2d14afab03340ce5f6c81b703c86a0c570653ae586534e095fb1)
            }
        } else {
            thisBaseRate = baseRate;
            thisRateMultiplier = rateMultiplier;
        }

        if (utilRate > 90 ether) {
            // scale rate proportionally up to 100%

            utilRate = utilRate.sub(90 ether);
            if (utilRate > 10 ether)
                utilRate = 10 ether;

            maxRate = thisRateMultiplier
                .add(thisBaseRate)
                .mul(90)
                .div(100);

            nextRate = utilRate
                .mul(SafeMath.sub(100 ether, maxRate))
                .div(10 ether)
                .add(maxRate);
        } else {
            nextRate = utilRate
                .mul(thisRateMultiplier)
                .div(10**20)
                .add(thisBaseRate);

            minRate = thisBaseRate;
            maxRate = thisRateMultiplier
                .add(thisBaseRate);

            if (nextRate < minRate)
                nextRate = minRate;
            else if (nextRate > maxRate)
                nextRate = maxRate;
        }
    }

    function _getAllInterest()
        internal
        view
        returns (
            uint256 interestOwedPerDay,
            uint256 interestUnPaid)
    {
        (,,interestOwedPerDay,interestUnPaid) = IBZx(bZxContract).getLenderInterestForOracle(
            address(this),
            bZxOracle, // (leave as original value)
            address(_getDai()) // same as interestTokenAddress
        );

        interestUnPaid = interestUnPaid
            .mul(spreadMultiplier)
            .div(10**20);
    }

    function _getBorrowAmountAndRate(
        bytes32 loanOrderHash,
        uint256 depositAmount,
        bool useFixedInterestModel)
        internal
        view
        returns (uint256 borrowAmount, uint256 interestRate)
    {
        LoanData memory loanData = loanOrderData[loanOrderHash];
        require(loanData.initialMarginAmount != 0, "33");

        interestRate = _nextBorrowInterestRate2(
            depositAmount
                .mul(10**20)
                .div(loanData.initialMarginAmount),
            totalAssetSupply(),
            useFixedInterestModel
        );

        // assumes that loan, collateral, and interest token are the same
        borrowAmount = depositAmount
            .mul(10**40)
            .div(_adjustValue(
                interestRate,
                loanData.maxDurationUnixTimestampSec,
                loanData.initialMarginAmount))
            .div(loanData.initialMarginAmount);
    }

    function _totalAssetSupply(
        uint256 interestUnPaid)
        internal
        view
        returns (uint256 assetSupply)
    {
        if (totalSupply_ != 0) {
            uint256 assetsBalance = burntTokenReserved; // temporary holder when flash lending
            if (assetsBalance == 0) {
                assetsBalance = _underlyingBalance()
                    .add(totalAssetBorrow);
            }

            return assetsBalance
                .add(interestUnPaid);
        }
    }

    function _getLowUtilBaseRate()
        internal
        view
        returns (uint256 lowUtilBaseRate)
    {
        //keccak256("iToken_LowUtilBaseRate")
        assembly {
            lowUtilBaseRate := sload(0x3d82e958c891799f357c1316ae5543412952ae5c423336f8929ed7458039c995)
        }
    }

    function _adjustValue(
        uint256 interestRate,
        uint256 maxDuration,
        uint256 marginAmount)
        internal
        pure
        returns (uint256)
    {
        return maxDuration != 0 ?
            interestRate
                .mul(10**20)
                .div(31536000) // 86400 * 365
                .mul(maxDuration)
                .div(marginAmount)
                .add(10**20) :
            10**20;
    }

    function _utilizationRate(
        uint256 assetBorrow,
        uint256 assetSupply)
        internal
        pure
        returns (uint256)
    {
        if (assetBorrow != 0 && assetSupply != 0) {
            // U = total_borrow / total_supply
            return assetBorrow
                .mul(10**20)
                .div(assetSupply);
        }
    }

    function _getChai()
        internal
        pure
        returns (iChai)
    {
        return chai;
    }

    function _getPot()
        internal
        pure
        returns (iPot)
    {
        return pot;
    }

    function _getDai()
        internal
        pure
        returns (ERC20)
    {
        return dai;
    }

    function rmul(
        uint256 x,
        uint256 y)
        internal
        pure
        returns (uint256 z)
    {
        require(y == 0 || (z = x * y) / y == x);
		z /= RAY;
    }
    function rpow(
        uint256 x,
        uint256 n,
        uint256 base)
        public
        pure
        returns (uint256 z)
    {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0,0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0,0) }
                    x := div(xxRound, base)
                    if mod(n,2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0,0) }
                        z := div(zxRound, base)
                    }
                }
            }
        }
    }

    /* Oracle-Only functions */

    // called only by BZxOracle when a loan is partially or fully closed
    function closeLoanNotifier(
        BZxObjects.LoanOrder memory loanOrder,
        BZxObjects.LoanPosition memory loanPosition,
        address loanCloser,
        uint256 closeAmount,
        bool isLiquidation)
        public
        onlyOracle
        returns (bool)
    {
        _settleInterest();
        _dsrDeposit();

        LoanData memory loanData = loanOrderData[loanOrder.loanOrderHash];
        if (loanData.loanOrderHash == loanOrder.loanOrderHash) {
            totalAssetBorrow = totalAssetBorrow > closeAmount ?
                totalAssetBorrow.sub(closeAmount) : 0;

            emit Repay(
                loanOrder.loanOrderHash,    // loanOrderHash
                loanPosition.trader,        // borrower
                loanCloser,                 // closer
                closeAmount,                // amount
                isLiquidation               // isLiquidation
            );

            if (closeAmount == 0)
                return true;

            // checkpoint supply since the base protocol borrow stats have changed
            checkpointSupply = _totalAssetSupply(0);

            return true;
        } else {
            return false;
        }
    }


    /* Owner-Only functions */

    function updateSettings(
        address settingsTarget,
        bytes memory callData)
        public
    {
        if (msg.sender != owner) {
            address _lowerAdmin;
            address _lowerAdminContract;

            //keccak256("iToken_LowerAdminAddress")
            //keccak256("iToken_LowerAdminContract")
            assembly {
                _lowerAdmin := sload(0x7ad06df6a0af6bd602d90db766e0d5f253b45187c3717a0f9026ea8b10ff0d4b)
                _lowerAdminContract := sload(0x34b31cff1dbd8374124bd4505521fc29cab0f9554a5386ba7d784a4e611c7e31)
            }
            require(msg.sender == _lowerAdmin && settingsTarget == _lowerAdminContract);
        }

        address currentTarget = target_;
        target_ = settingsTarget;

        (bool result,) = address(this).call(callData);

        uint256 size;
        uint256 ptr;
        assembly {
            size := returndatasize
            ptr := mload(0x40)
            returndatacopy(ptr, 0, size)
            if eq(result, 0) { revert(ptr, size) }
        }

        target_ = currentTarget;

        assembly {
            return(ptr, size)
        }
    }
}
