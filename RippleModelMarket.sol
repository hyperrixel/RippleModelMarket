// SPDX-License-Identifier: Copyright
pragma solidity ^0.8.18;

/// @title RippleModelMarket
/// @author rixel (Dr. Axel Ország-Krisz and Dr. Richárd Ádám Vécsey)
/// @notice RippleModelMarket is a blockchain powered marketplace for artificial
/// @notice intelligence and machine learning models.
/// @notice ---
/// @notice Made for NEW HORIZON Hackathon in 2023
contract RippleModelMarket {

    // ###############
    // # CONSTRUCTOR #
    // ###############

    /// @notice Construct the contract
    /// @param  sentence_       System password to store
    /// @notice                 Protect system password carefully. It is needed
    /// @notice                 for all root operations and there are no backdoors.
    constructor(string memory sentence_) {

        rootUser = payable(msg.sender);
        rootKey = keccak256(abi.encodePacked(sentence_));
        availableBalance = 0;
        feePercentage = DEFAULT_FEE_PERCENTAGE;
        setProfitRate();
        feedbackPrice = DEFAULT_FEEDBACK_PRICE;

    }

    // ##################
    // # USER FUNCTIONS #
    // ##################

    /// @notice Add a new model
    /// @param  auctionState_   Description of how to sell the model
    /// @param  sellPrice_      Price to sell the model for
    /// @param  auctionLimit_   Time limit for accepting bids
    /// @param  rentState_      Information about the rental availability
    /// @param  rentPrice_      Price to rent
    /// @notice                 In case of time limit auction sell price is not
    /// @notice                 taken into consideration.
    /// @notice ---
    /// @notice ModelAdded() event is emitted on success.
    /// @dev    Frontend must watch the event to get the model Id to be able to
    /// @dev    to send model information and model data to the database.
    function addModel(uint8 auctionState_, uint256 sellPrice_,
                      uint256 auctionLimit_, uint8 rentState_,
                      uint256 rentPrice_) external payable returns (uint) {

        AuctionStates _auctionInfo = auctionState(auctionState_);
        if (_auctionInfo == AuctionStates.AuctionWithTimeLimit) {
            require(auctionLimit_ > block.timestamp,
                    'Time limit of auction must be in the future.');
        } else if (_auctionInfo == AuctionStates.AuctionWithPriceLimit) {
            require(sellPrice_ > 0,
                    'Price limit of auction must be in non-zero.');
        }
        RentStates _rentInfo = rentState(rentState_);
        if (_rentInfo == RentStates.ForRent) {
            require(rentPrice_ > 0,
                    'Rent price must be greater than zero.');
        }
        uint _id = models.length;
        models.push(Model(msg.sender, block.timestamp, block.timestamp,
                          _auctionInfo, sellPrice_, auctionLimit_, address(0),
                          0, _rentInfo, rentPrice_, 0, 0, 0));
        emit ModelAdded(_id);
        return _id;

    }

    /// @notice Take a bid to model which is under auction
    /// @param  id_             Id of the model to take a bid for
    /// @notice                 Message value is considered as the amount of the
    /// @notice                 bid while message sender is considered as taker.
    /// @notice ---
    /// @notice ModelNewBid() event is emitted on success.
    function bid(uint id_) onlyExistingModel(id_) onlyModelForBid(id_)
                 onlyBestBid(id_) onlyUnlockedSender() external payable {

        lock(msg.sender);
        uint256 _newBalance = balances[msg.sender] + msg.value;
        uint256 _newLockedBalance = lockedBalances[msg.sender];
        require(_newBalance > balances[msg.sender] && _newBalance >= msg.value,
                'Addition overflow at bid taker balance calculation.');
        if (msg.sender != models[id_].topBidOwner) {
            _newLockedBalance += msg.value;
            uint256 _newPreviousBidderLockedBalance = lockedBalances[models[id_].topBidOwner] - models[id_].topBidPrice;
            require(_newPreviousBidderLockedBalance <= lockedBalances[models[id_].topBidOwner],
                    'Subtraction overflow at previous bid taker locked balance calculation.');
            lockedBalances[models[id_].topBidOwner] = _newPreviousBidderLockedBalance;
        } else {
            uint256 _difference = msg.value - models[id_].topBidPrice;
            _newLockedBalance += _difference;
        }
        require(_newLockedBalance > lockedBalances[msg.sender] && _newLockedBalance >= msg.value,
                'Addition overflow at bid taker locked balance calculation.');
        balances[msg.sender] = _newBalance;
        lockedBalances[msg.sender] = _newLockedBalance;
        models[id_].topBidOwner = msg.sender;
        models[id_].topBidPrice = msg.value;
        unlock(msg.sender);
        emit ModelNewBid(id_, models[id_].topBidOwner, models[id_].topBidPrice,
                         block.timestamp);

    }

    /// @notice Buy a model which is for sale
    /// @param  id_             Id of the model to buy
    /// @notice                 Message value is considered as the price and
    /// @notice                 message sender is considered as the new owner.
    /// @notice                 The rest of message value is added to the
    /// @notice                 balance of the message sender.
    /// @notice ---
    /// @notice ModelNewOwner() event is emitted on success.
    function buy(uint id_) onlyExistingModel(id_) onlyModelForSale(id_)
                 onlyEnoughPriceToBuy(id_) onlyUnlockedParties(id_)
                 external payable {

        lock(msg.sender);
        lock(models[id_].owner);
        uint256 _newAvailableBalance = reckonFee(models[id_].sellPrice);
        uint256 _newOwnerBalance = reckonProfit(models[id_].sellPrice,
                                                balances[models[id_].owner]);
        uint256 _newBuyerBalance = reckonRest(models[id_].sellPrice,
                                              balances[msg.sender]);
        address _previousOwner = models[id_].owner;
        availableBalance = _newAvailableBalance;
        balances[models[id_].owner] = _newOwnerBalance;
        balances[msg.sender] = _newBuyerBalance;
        models[id_].owner = msg.sender;
        models[id_].ownerSince = block.timestamp;
        models[id_].auctionState = AuctionStates.NotSet;
        unlock(msg.sender);
        unlock(_previousOwner);
        emit ModelNewOwner(id_, _previousOwner, models[id_].owner,
                           models[id_].ownerSince);

    }

    /// @notice Close the running auction of a model
    /// @param  id_             Id of the model to close the auction for
    /// @notice ---
    /// @notice ModelNewOwner() event is emitted on success.
    function closeAuction(uint id_) onlyExistingModel(id_) onlyModelOwner(id_)
                          onlyUnlockedAuctionParties(id_) external {

        require(models[id_].auctionState == AuctionStates.AuctionWithPriceLimit
                || models[id_].auctionState == AuctionStates.AuctionWithTimeLimit,
                'Model must be under auction to perform this action');
        require(models[id_].owner != address(0) && models[id_].topBidPrice > 0,
                'Model does not have a valid bid.');
        if (models[id_].auctionState == AuctionStates.AuctionWithTimeLimit) {
            require(models[id_].auctionLimit <= block.timestamp,
                    'Time limit auction is not yet expired.');
        } else if (models[id_].auctionState == AuctionStates.AuctionWithPriceLimit) {
            require(models[id_].topBidPrice >= models[id_].sellPrice,
                    'Top bid is too low.');
        }
        lock(models[id_].owner);
        lock(models[id_].topBidOwner);
        uint256 _newAvailableBalance = reckonFee(models[id_].topBidPrice);
        uint256 _newOwnerBalance = reckonProfit(models[id_].topBidPrice,
                                                balances[models[id_].owner]);
        (uint256 _newBuyerBalance, uint256 _newBuyerLocked) = reckonTopBid(id_);
        address _previousOwner = models[id_].owner;
        availableBalance = _newAvailableBalance;
        balances[models[id_].owner] = _newOwnerBalance;
        balances[models[id_].topBidOwner] = _newBuyerBalance;
        lockedBalances[models[id_].topBidOwner] = _newBuyerLocked;
        models[id_].auctionState = AuctionStates.NotSet;
        models[id_].owner = models[id_].topBidOwner;
        models[id_].ownerSince = block.timestamp;
        models[id_].topBidOwner = address(0);
        models[id_].topBidPrice = 0;
        unlock(_previousOwner);
        unlock(models[id_].owner);
        emit ModelNewOwner(id_, _previousOwner, models[id_].owner,
                           models[id_].ownerSince);

    }

    /// @notice Give a dislike feedback for a model
    /// @param  id_             Id of the model to give a dislike for
    /// @notice                 Message value is considered as the feedback price.
    /// @notice                 The rest of message value is added to the
    /// @notice                 balance of the message sender.
    /// @notice ---
    /// @notice ModelNewFeedback() event is emitted on success.
    function dislike(uint id_) onlyExistingModel(id_) onlyUnlockedSender()
                     onlyEnoughPriceToFeedback() external payable {

        lock(msg.sender);
        uint256 _newBalance = reckonRest(feedbackPrice, balances[msg.sender]);
        uint256 _newAvailableBalance = reckonFeedback();
        availableBalance = _newAvailableBalance;
        balances[msg.sender] = _newBalance;
        unlock(msg.sender);
        models[id_].dislikes += 1;
        emit ModelNewFeedback(id_, false);

    }

    /// @notice Get fee percentage
    /// @return uint8           Percentage of the actual fee.
    /// @notice                 The same percentage is used for rent and sell.
    function getFeePercentage() external view returns (uint8) {

        return feePercentage;

    }

    /// @notice Get feedback price
    /// @return uint256         The price of the feedback in the smallest unit.
    function getFeedbackPrice() external view returns (uint256) {

        return feedbackPrice;

    }

    /// @notice Get the information of an existing model
    /// @param  id_             Id of the model to get
    /// @return Model           All the information of the requested model
    function getModel(uint id_) onlyExistingModel(id_) external view
                      returns (Model memory) {

        return models[id_];

    }

    /// @notice Get the number of models
    /// @return uint            Total number of stored models
    /// @dev    This number can be used to loop over models in the user side.
    function getNumberOfModels() external view returns (uint) {

        return models.length;

    }

    /// @notice Get the number of proofs of rental
    /// @return uint            Total number of stored proofs of rental
    /// @dev    This number can be used to loop over proofs in the user side.
    function getNumberOfRentals() external view returns (uint) {

        return proofOfRentals.length;

    }

    /// @notice Get the information of an existing proof of rental
    /// @param  id_             Id of the proof of rental to get
    /// @return ProofOfRental   All the information of the requested rental
    function getProofOfRental(uint id_) onlyExistingRental(id_) external view
                              returns (ProofOfRental memory) {

        return proofOfRentals[id_];

    }

    /// @notice Get the address of the operator
    /// @return address         The address of the system root
    /// @notice                 This address is the source of transparency.
    function getRootAddress() external view returns (address) {

        return rootUser;

    }

    /// @notice Give a like feedback for a model
    /// @param  id_             Id of the model to give a like for
    /// @notice                 Message value is considered as the feedback price.
    /// @notice                 The rest of message value is added to the
    /// @notice                 balance of the message sender.
    /// @notice ---
    /// @notice ModelNewFeedback() event is emitted on success.
    function like(uint id_) onlyExistingModel(id_) onlyUnlockedSender()
                  onlyEnoughPriceToFeedback() external payable {

        lock(msg.sender);
        uint256 _newBalance = reckonRest(feedbackPrice, balances[msg.sender]);
        uint256 _newAvailableBalance = reckonFeedback();
        availableBalance = _newAvailableBalance;
        balances[msg.sender] = _newBalance;
        unlock(msg.sender);
        models[id_].likes += 1;
        emit ModelNewFeedback(id_, true);

    }

    /// @notice Rent a model which is available for rent
    /// @param  id_             Id of the model to rent
    /// @notice                 Message value is considered as the rent price
    /// @notice                 and message sender is considered as the renter.
    /// @notice                 The rest of message value is added to the
    /// @notice                 balance of the message sender.
    /// @notice ---
    /// @notice ModelNewRent() event is emitted on success.
    function rent(uint id_) onlyExistingModel(id_) onlyModelForRent(id_)
                  onlyEnoughPriceToRent(id_) onlyUnlockedParties(id_)
                  external payable {

        lock(msg.sender);
        lock(models[id_].owner);
        uint256 _newAvailableBalance = reckonFee(models[id_].rentPrice);
        uint256 _newOwnerBalance = reckonProfit(models[id_].rentPrice,
                                                balances[models[id_].owner]);
        uint256 _newRenterBalance = reckonRest(models[id_].rentPrice,
                                               balances[msg.sender]);
        uint _rentId = proofOfRentals.length;
        availableBalance = _newAvailableBalance;
        balances[models[id_].owner] = _newOwnerBalance;
        balances[msg.sender] = _newRenterBalance;
        proofOfRentals.push(ProofOfRental(id_, msg.sender, block.timestamp));
        models[id_].countOfRents += 1;
        unlock(msg.sender);
        unlock(models[id_].owner);
        emit ModelNewRent(proofOfRentals[_rentId].modelId, _rentId,
                          proofOfRentals[_rentId].renter,
                          proofOfRentals[_rentId].timestamp);

    }

    /// @notice Change auction state of a model
    /// @param  id_             Id of the model to change the sate for
    /// @param  newState_       Description of how to sell the model
    /// @param  sellPrice_      Price to sell the model for
    /// @param  auctionLimit_   Time limit for accepting bids
    /// @notice ---
    /// @notice ModelChanged() event is emitted on success.
    function setAuction(uint id_, uint8 newState_, uint256 sellPrice_,
                        uint256 auctionLimit_) onlyExistingModel(id_)
                        onlyModelOwner(id_) external {

        require(models[id_].auctionState != AuctionStates.AuctionWithPriceLimit
                && models[id_].auctionState != AuctionStates.AuctionWithTimeLimit,
                'Model must not be under auction to perform this action');
        AuctionStates _auctionState = auctionState(newState_);
        if (_auctionState == AuctionStates.AuctionWithTimeLimit) {
            require(auctionLimit_ > block.timestamp,
                    'Time limit of auction must be in the future.');
        } else if (_auctionState == AuctionStates.AuctionWithPriceLimit) {
            require(sellPrice_ > 0,
                    'Price limit of auction must be in non-zer.');
        }
        models[id_].auctionState = _auctionState;
        models[id_].sellPrice = sellPrice_;
        models[id_].auctionLimit = auctionLimit_;
        emit ModelChanged(id_);

    }

    /// @notice Change rental state of a model
    /// @param  id_             Id of the model to change the sate for
    /// @param  newState_       Information about the rental availability
    /// @param  rentPrice_      Price to rent
    /// @notice ---
    /// @notice ModelChanged() event is emitted on success.
    function setRent(uint id_, uint8 newState_, uint256 rentPrice_)
                     onlyExistingModel(id_) onlyModelOwner(id_) external {

        RentStates _rentState = rentState(newState_);
        if (_rentState == RentStates.ForRent) {
            require(rentPrice_ > 0,
                    'Rent price must be greater than zero.');
        }
        models[id_].rentState = _rentState;
        models[id_].rentPrice = rentPrice_;
        emit ModelChanged(id_);

    }

    /// @notice Withdraw the available balance
    /// @param  amount_         Amount to withdraw. If 0 is given, total
    /// @notice                 available balance will be withdrawn.
    /// @notice ---
    /// @notice Withdraw() event is emitted on success.
    function withdraw(uint256 amount_) onlyUnlockedSender() external {

        lock(msg.sender);
        uint256 _availableBalance = balances[msg.sender] - lockedBalances[msg.sender];
        require(_availableBalance <= balances[msg.sender],
                'Subtraction overflow at available balance calculation.');
        uint256 _transferValue = 0;
        if (amount_ == 0) {
            _transferValue = _availableBalance;
        } else {
            require(amount_ <= _availableBalance,
                    'Available balance is not enough to withdraw the desired value.');
            _transferValue = amount_;
        }
        require(_transferValue > 0, 'Nothing to withdraw.');
        uint256 _newBalance = balances[msg.sender] - _transferValue;
        require(_newBalance < balances[msg.sender],
                'Subtraction overflow at rest balance calculation.');
        balances[msg.sender] = _newBalance;
        address payable _recipient = payable(msg.sender);
        bool _success = _recipient.send(_transferValue);
        require(_success, 'Failed to withdraw.');
        unlock(msg.sender);
        emit Withdraw(msg.sender, _transferValue);

    }

    // ###################
    // # ADMIN FUNCTIONS #
    // ###################

    /// @notice Withdraw the available system balance
    /// @param  sentence_       System password to verify
    /// @param  amount_         Amount to withdraw. If 0 is given, total
    /// @notice                 available system balance will be withdrawn.
    function adminWithdraw(string calldata sentence_, uint256 amount_)
                           onlyAdmin(sentence_) external {

        uint256 _transferValue = 0;
        if (amount_ == 0) {
            _transferValue = availableBalance;
        } else {
            require(amount_ <= availableBalance,
                    'Available balance is not enough to withdraw the desired value.');
            _transferValue = amount_;
        }
        require(_transferValue > 0, 'Nothing to withdraw.');
        uint256 _newBalance = availableBalance - _transferValue;
        require(_newBalance < availableBalance,
                'Subtraction overflow at rest balance calculation.');
        availableBalance = _newBalance;
        address payable _recipient = payable(msg.sender);
        bool _success = _recipient.send(_transferValue);
        require(_success, 'Failed to withdraw.');

    }

    /// @notice Change system password
    /// @param  sentence_       System password to verify
    /// @param  newSentence_    New system password to store
    /// @notice                 Protect system password carefully. It is needed
    /// @notice                 for all root operations and there are no backdoors.
    function changeSentence(string calldata sentence_,
                            string calldata newSentence_) onlyAdmin(sentence_)
                            external {

        rootKey = keccak256(abi.encodePacked(newSentence_));

    }

    /// @notice Root operation to force the close of a model's auction
    /// @param  sentence_       System password to verify
    /// @param  id_             Id of the model to close auction for
    /// @dev    This operation should taken only if model owner does not care
    /// @dev    about the auction of the model.
    function forceCloseAuction(string calldata sentence_, uint id_)
                               onlyAdmin(sentence_) onlyExistingModel(id_)
                               external {

        if(models[id_].owner != address(0) && models[id_].topBidPrice > 0) {
            lock(models[id_].owner);
            lock(models[id_].topBidOwner);
            uint256 _newAvailableBalance = reckonFee(models[id_].topBidPrice);
            uint256 _newOwnerBalance = reckonProfit(models[id_].topBidPrice,
                                                    balances[models[id_].owner]);
            (uint256 _newBuyerBalance, uint256 _newBuyerLocked) = reckonTopBid(id_);
            address _previousOwner = models[id_].owner;
            availableBalance = _newAvailableBalance;
            balances[models[id_].owner] = _newOwnerBalance;
            balances[models[id_].topBidOwner] = _newBuyerBalance;
            lockedBalances[models[id_].topBidOwner] = _newBuyerLocked;
            models[id_].owner = models[id_].topBidOwner;
            models[id_].ownerSince = block.timestamp;
            unlock(_previousOwner);
            unlock(models[id_].owner);
        }
        models[id_].auctionState = AuctionStates.NotSet;
        models[id_].topBidOwner = address(0);
        models[id_].topBidPrice = 0;

    }

    /// @notice Root operation to force the lock of a user
    /// @param  sentence_       System password to verify
    /// @param  user_           The address of a user to lock
    /// @dev    This operation should taken only if there are users who violate
    /// @dev    any rules.
    function forceLock(string calldata sentence_, address user_)
                       onlyAdmin(sentence_) external {

        lock(user_);
    
    }

    /// @notice Root operation to force the unlock of a user
    /// @param  sentence_       System password to verify
    /// @param  user_           The address of a user to unlock
    /// @dev    This operation should taken only if there are users who failed
    /// @dev    in any operation and is locked permanently. Before unlocking a
    /// @dev    a user an extensive examination should be taken to remark
    /// @dev    potential hacking activity.
    function forceUnlock(string calldata sentence_, address user_)
                         onlyAdmin(sentence_) external {

        unlock(user_);
    
    }

    /// @notice Root operation to change fee percentage
    /// @param  sentence_       System password to verify
    /// @param  newValue_       New fee percentage value
    function setFeePercentage(string calldata sentence_, uint8 newValue_)
                              onlyAdmin(sentence_) external {

        require(newValue_ < 100, 'Fee percentage must be less than 100.');
        feePercentage = newValue_;
        setProfitRate();

    }

    /// @notice Root operation to change feedback price
    /// @param  sentence_       System password to verify
    /// @param  newValue_       New feedback price value
    function setFeedbackPrice(string calldata sentence_, uint8 newValue_)
                              onlyAdmin(sentence_) external {

        feedbackPrice = newValue_;

    }

    // ######################
    // # INTERNAL FUNCTIONS #
    // ######################

    /// @notice Convert numeric value to AuctionStates enum value
    /// @param  value_          The value to convert
    /// @return AuctionStates   The converted value
    function auctionState(uint8 value_) internal pure returns (AuctionStates) {

        AuctionStates _result = AuctionStates.NotSet;
        if (value_ == 4) {
            _result = AuctionStates.AuctionWithTimeLimit;
        } else if (value_ == 3) {
            _result = AuctionStates.AuctionWithPriceLimit;
        } else if (value_ == 2) {
            _result = AuctionStates.ForSaleWIthoutAuction;
        } else if (value_ == 1) {
            _result = AuctionStates.NotForSale;
        } else if (value_ != 0) {
            revert('Invalid auction state given. It must be between 0 - 4.');
        }
        return _result;

    }

    /// @notice Calculate the value of the fee
    /// @param  baseValue_      The value to use for the fee calculation
    /// @return uint256         The calculated fee
    /// @dev    This function ensures overflow protected workflow aka safe math.
    function reckonFee(uint256 baseValue_) internal view returns (uint256) {

        uint256 _fee = baseValue_ * feePercentage / 100;
        require(_fee < baseValue_,
                'Multiplication overflow at fee calculation.');
        uint256 _result = availableBalance + _fee;
        require(_result > availableBalance && _result >= _fee,
                'Addition overflow at balance calculation.');
        return _result;

    }

    /// @notice Calculate the new available balance for the system at a feedback
    /// @return uint256         The new available balance of the system
    /// @dev    This function ensures overflow protected workflow aka safe math.
    function reckonFeedback() internal view returns (uint256) {

        uint256 _result = availableBalance + feedbackPrice;
        require(_result > availableBalance && _result >= feedbackPrice,
                'Addition overflow at balance calculation.');
        return _result;

    }

    /// @notice Calculate the value of the profit
    /// @param  baseValue_      The value to use for the profit calculation
    /// @return uint256         The calculated profit
    /// @dev    This function ensures overflow protected workflow aka safe math.
    function reckonProfit(uint256 baseValue_, uint256 balance_) internal view
                          returns (uint256) {

        uint256 _profit = baseValue_ * profitRate / 100;
        require(_profit < baseValue_,
                'Multiplication overflow at profit calculation.');
        uint256 _result = balance_ + _profit;
        require(_result > balance_ && _result >= _profit,
                'Addition overflow at owner\'s balance calculation.');
        return _result;

    }

    /// @notice Calculate the rest of message value
    /// @param  targetValue_    Value that sender must target to pay
    /// @param  balance_        Tha balance where the value should be added
    /// @return uint256         The calculated new balance with the rest
    /// @dev    This function ensures overflow protected workflow aka safe math.
    function reckonRest(uint256 targetValue_, uint256 balance_) internal view
                        returns (uint256) {

        uint256 _result = balance_;
        if (msg.value != targetValue_) {
            uint256 _plusValue = msg.value - targetValue_;
            _result += _plusValue;
            require(_result > balance_ && _result >= _plusValue,
                    'Addition overflow at balance calculation.');
        }
        return _result;

    }

    /// @notice Calculate the new balance and locked balance for the bid taker
    /// @param  id_             Id of the model to use for the calculation
    /// @return uint256         The calculated new balance
    /// @return uint256         The calculated new locked balance
    /// @dev    This function ensures overflow protected workflow aka safe math.
    function reckonTopBid(uint id_) internal view returns (uint256, uint256) {

        uint256 _balance = balances[models[id_].topBidOwner] - models[id_].topBidPrice;
        uint256 _locked = lockedBalances[models[id_].topBidOwner] - models[id_].topBidPrice;
        
        return (_balance, _locked);

    }

    /// @notice Convert numeric value to RentStates enum value
    /// @param  value_          The value to convert
    /// @return RentStates      The converted value
    /// @dev    This function ensures overflow protected workflow aka safe math.
    function rentState(uint8 value_) internal pure returns (RentStates) {

        RentStates _result = RentStates.NotSet;
        if (value_ == 2) {
            _result = RentStates.ForRent;
        } else if (value_ == 1) {
            _result = RentStates.NotForRent;
        } else if (value_ != 0) {
            revert('Invalid rent state given. It must be between 0 - 3.');
        }
        return _result;

    }

    // #####################
    // # PRIVATE FUNCTIONS #
    // #####################

    /// @notice Lock a user
    /// @param  target_         The address of the user to lock
    function lock(address target_) private {

        locked[target_] = true;

    }

    /// @notice Set profit rate based on fee percentage
    /// @dev    This function ensures overflow protected workflow aka safe math.
    /// @dev    This function must be called after changing the fee percentage.
    function setProfitRate() private {

        uint8 _newRate = 100 - feePercentage;
        require(_newRate < 100 && _newRate > feePercentage,
                'Math error on setting profit rate.');
        profitRate = _newRate;

    }

    /// @notice Unlock a user
    /// @param  target_         The address of the user to unlock
    function unlock(address target_) private {

        locked[target_] = false;

    }

    // #############
    // # MODIFIERS #
    // #############

    /// @notice Verifies root credentials
    /// @param  sentence_       System password to verify
    modifier onlyAdmin(string calldata sentence_) {

        require(msg.sender == rootUser, 'Only root can perform this action.');
        require(keccak256(abi.encodePacked(sentence_)) == rootKey,
                'This action requires authorization.');
        _;

    }

    /// @notice Verifies if message value is enough to be the best bid
    /// @param  id_             Id of the model verify best bid eligibility for
    modifier onlyBestBid(uint id_) {

        require(models[id_].topBidPrice < msg.value,
                'New bid most be better than the top bid.');
        _;

    }

    /// @notice Verifies if message value is enough to buy the model
    /// @param  id_             Id of the model verify buy eligibility for
    modifier onlyEnoughPriceToBuy(uint id_) {

        require(models[id_].sellPrice <= msg.value,
                'Sent value is not enough to buy this model.');
        _;

    }

    /// @notice Verifies if message value is enough to pay for giving a feedback
    modifier onlyEnoughPriceToFeedback() {

        require(feedbackPrice <= msg.value,
                'Sent value is not enough to give feedback.');
        _;

    }

    /// @notice Verifies if message value is enough to rent the model
    /// @param  id_             Id of the model verify rental eligibility for
    modifier onlyEnoughPriceToRent(uint id_) {

        require(models[id_].rentPrice <= msg.value,
                'Sent value is not enough to rent this model.');
        _;

    }

    /// @notice Verifies the existence of a model
    /// @param  id_             Id of the model to verify
    modifier onlyExistingModel(uint id_) {

        require(id_ < models.length, 'Tried to access non-existing model.');
        _;

    }

    /// @notice Verifies the existence of a proof of rental
    /// @param  id_             Id of the proof of rental to verify
    modifier onlyExistingRental(uint id_) {

        require(id_ < proofOfRentals.length,
                'Tried to access non-existing proof of rental.');
        _;

    }

    /// @notice Verifies whether the model is available to accept bids
    /// @param  id_             Id of the model to verify
    modifier onlyModelForBid(uint id_) {

        require(models[id_].auctionState == AuctionStates.AuctionWithPriceLimit
                || (models[id_].auctionState == AuctionStates.AuctionWithTimeLimit
                    && models[id_].auctionLimit > block.timestamp),
                'Taking bids for this model is not available.');
        _;

    }

    /// @notice Verifies whether the model is for rent
    /// @param  id_             Id of the model to verify
    modifier onlyModelForRent(uint id_) {

        require(models[id_].rentState == RentStates.ForRent,
                'Renting this model is not available.');
        _;

    }

    /// @notice Verifies whether the model is for sale
    /// @param  id_             Id of the model to verify
    modifier onlyModelForSale(uint id_) {

        require(models[id_].auctionState == AuctionStates.ForSaleWIthoutAuction,
                'This model is not for direct sale.');
        _;

    }

    /// @notice Verifies whether the owner of the model tries to act
    /// @param  id_             Id of the model to verify
    modifier onlyModelOwner(uint id_) {

        require(models[id_].owner == msg.sender,
                'Only model owner can perform this action.');
        _;

    }

    /// @notice Verifies whether the model owner and top bid taker are unlocked
    /// @param  id_             Id of the model to verify the parties for
    modifier onlyUnlockedAuctionParties(uint id_) {

        require(locked[models[id_].owner] == false && locked[models[id_].topBidOwner] == false,
                'Affected auction parties must have unlocked state to perform this action.');
        _;

    }

    /// @notice Verifies whether the model owner and the message sender are unlocked
    /// @param  id_             Id of the model to verify the parties for
    modifier onlyUnlockedParties(uint id_) {

        require(locked[msg.sender] == false && locked[models[id_].owner] == false,
                'Affected parties must have unlocked state to perform this action.');
        _;

    }

    /// @notice Verifies whether the message sender is unlocked
    modifier onlyUnlockedSender() {

        require(locked[msg.sender] == false,
                'You must have unlocked state to perform this action.');
        _;

    }

    // ###################
    // # ADMIN VARIABLES #
    // ###################

    address payable private rootUser;
    bytes32 private rootKey;
    uint256 private availableBalance;

    // ###########
    // # STRUCTS #
    // ###########

    struct Model {

        address owner;
        uint256 created;
        uint256 ownerSince;
        AuctionStates auctionState;
        uint256 sellPrice;
        uint256 auctionLimit;
        address topBidOwner;
        uint256 topBidPrice;
        RentStates rentState;
        uint256 rentPrice;
        uint64 countOfRents;
        uint32 likes;
        uint32 dislikes;

    }

    struct ProofOfRental {

        uint modelId;
        address renter;
        uint256 timestamp;

    }

    // #############
    // # CONSTANTS #
    // #############

    uint8 constant private DEFAULT_FEE_PERCENTAGE = 10;
    uint256 constant private DEFAULT_FEEDBACK_PRICE = 1e18; // 1 XRP

    // #########
    // # ENUMS #
    // #########

    enum AuctionStates { NotSet, NotForSale, ForSaleWIthoutAuction,
                         AuctionWithPriceLimit, AuctionWithTimeLimit }

    enum RentStates { NotSet, NotForRent, ForRent }

    // ####################
    // # PUBLIC VARIABLES #
    // ####################

    // #####################
    // # PRIVATE VARIABLES #
    // #####################

    uint8 private feePercentage;
    uint256 private feedbackPrice;
    uint8 private profitRate;

    mapping(address => uint256) private balances;
    mapping(address => bool) private locked;
    mapping(address => uint256) private lockedBalances;
    Model[] private models;
    ProofOfRental[] private proofOfRentals;

    // ##########
    // # EVENTS #
    // ##########

    event ModelAdded(uint modelId_);
    event ModelChanged(uint modelId_);
    event ModelNewBid(uint modelId_, address taker_, uint256 price_, uint256 timestamp_);
    event ModelNewFeedback(uint modelId_, bool isLike_);
    event ModelNewOwner(uint modelId_, address previousOwner_, address newOwner_, uint256 timestamp_);
    event ModelNewRent(uint modelId_, uint proofId_, address renter_, uint256 timestamp_);
    event Withdraw(address owner_, uint256 amount_);

 }