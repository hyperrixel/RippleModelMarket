// SPDX-License-Identifier: Copyright
pragma solidity ^0.8.18;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/// @title RippleModelMarket
/// @author rixel (Dr. Axel Ország-Krisz and Dr. Richárd Ádám Vécsey)
/// @notice RippleModelMarket is a blockchain powered marketplace for artificial
/// @notice intelligence and machine learning models.
/// @notice ---
/// @notice Made for NEW HORIZON Hackathon in 2023
/// @notice This is a thinner version to comply with the Spurious Dragon standards.
/// @notice This version of the contract is ready to deploy anywhere on EVMs.
contract RippleModelMarket {

    using  SafeMath for uint256;

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
        profitRate = 100;
        profitRate = profitRate.sub(feePercentage);
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

        require(auctionState_ >= 0 && auctionState_ < 5, 'Auction state must be between 0 and 4.');
        if (auctionState_ == 4) {
            require(auctionLimit_ > block.timestamp,
                    'Time limit of auction must be in the future.');
        } else if (auctionState_ == 3) {
            require(sellPrice_ > 0,
                    'Price limit of auction must be in non-zero.');
        }
        require(rentState_ >= 0 && rentState_ < 3, 'Auction state must be between 0 and 2.');
        if (rentState_ == 2) {
            require(rentPrice_ > 0,
                    'Rent price must be greater than zero.');
        }
        uint _id = models.length;
        models.push(Model(msg.sender, block.timestamp, block.timestamp,
                          auctionState_, sellPrice_, auctionLimit_, address(0),
                          0, rentState_, rentPrice_, 0, 0, 0));
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
        balances[msg.sender] = balances[msg.sender].add(msg.value);
        lockedBalances[msg.sender] = lockedBalances[msg.sender].add(msg.value);
        lockedBalances[models[id_].topBidOwner] =
            lockedBalances[models[id_].topBidOwner].sub(models[id_].topBidPrice);
        models[id_].topBidOwner = msg.sender;
        models[id_].topBidPrice = msg.value;
        unlock(msg.sender);

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
        availableBalance = models[id_].sellPrice.mul(feePercentage).div(100);
        balances[models[id_].owner] = models[id_].sellPrice.mul(profitRate).div(100);
        balances[msg.sender] = balances[msg.sender].add(msg.value.sub(models[id_].sellPrice));

        address _previousOwner = models[id_].owner;
        models[id_].owner = msg.sender;
        models[id_].ownerSince = block.timestamp;
        models[id_].auctionState = 0;
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

        require(models[id_].auctionState == 3 || models[id_].auctionState == 4,
                'Model must be under auction to perform this action');
        require(models[id_].owner != address(0) && models[id_].topBidPrice > 0,
                'Model does not have a valid bid.');
        if (models[id_].auctionState == 4) {
            require(models[id_].auctionLimit <= block.timestamp,
                    'Time limit auction is not yet expired.');
        } else if (models[id_].auctionState == 3) {
            require(models[id_].topBidPrice >= models[id_].sellPrice,
                    'Top bid is too low.');
        }
        reckonAuction(id_);

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
        balances[msg.sender] = balances[msg.sender].add(msg.value.sub(feedbackPrice));
        availableBalance = availableBalance.add(feedbackPrice);
        unlock(msg.sender);
        models[id_].dislikes += 1;

    }

    /// @notice Get fee percentage
    /// @return uint8           Percentage of the actual fee.
    /// @notice                 The same percentage is used for rent and sell.
    function getFeePercentage() external view returns (uint256) {

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
        availableBalance = availableBalance.add(feedbackPrice);
        balances[msg.sender] = balances[msg.sender].add(msg.value.sub(feedbackPrice));
        unlock(msg.sender);
        models[id_].likes += 1;

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

        availableBalance = models[id_].rentPrice.mul(feePercentage).div(100);
        balances[models[id_].owner] = models[id_].rentPrice.mul(profitRate).div(100);
        balances[msg.sender] = balances[msg.sender].add(msg.value.sub(models[id_].rentPrice));
        uint _rentId = proofOfRentals.length;
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

        require(models[id_].auctionState != 3 && models[id_].auctionState != 4,
                'Model must not be under auction to perform this action');
        require(newState_ >= 0 && newState_ < 5, 'Auction state must be between 0 and 4.');
        if (newState_ == 4) {
            require(auctionLimit_ > block.timestamp,
                    'Time limit of auction must be in the future.');
        } else if (newState_ == 3) {
            require(sellPrice_ > 0,
                    'Price limit of auction must be in non-zer.');
        }
        models[id_].auctionState = newState_;
        models[id_].sellPrice = sellPrice_;
        models[id_].auctionLimit = auctionLimit_;

    }

    /// @notice Change rental state of a model
    /// @param  id_             Id of the model to change the sate for
    /// @param  newState_       Information about the rental availability
    /// @param  rentPrice_      Price to rent
    /// @notice ---
    /// @notice ModelChanged() event is emitted on success.
    function setRent(uint id_, uint8 newState_, uint256 rentPrice_)
                     onlyExistingModel(id_) onlyModelOwner(id_) external {

        require(newState_ >= 0 && newState_ < 3, 'Auction state must be between 0 and 2.');
        if (newState_ == 2) {
            require(rentPrice_ > 0,
                    'Rent price must be greater than zero.');
        }
        models[id_].rentState = newState_;
        models[id_].rentPrice = rentPrice_;

    }

    /// @notice Withdraw the available balance
    /// @notice ---
    /// @notice Withdraw() event is emitted on success.
    function withdraw() onlyUnlockedSender() external {

        lock(msg.sender);

        uint256 _transferValue = balances[msg.sender].sub(lockedBalances[msg.sender]);
        require(_transferValue > 0, 'Nothing to withdraw.');
        balances[msg.sender] = balances[msg.sender].sub(_transferValue);
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

        uint256 _transferValue = availableBalance;
        require(amount_ <= _transferValue,
                'Available balance is not enough to withdraw the desired value.');
        if (amount_ > 0) {
            _transferValue = amount_;
        }
        require(_transferValue > 0, 'Nothing to withdraw.');
        availableBalance = availableBalance.sub(_transferValue);
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
            reckonAuction(id_);
        }
        models[id_].auctionState = 0;
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
        profitRate = 100;
        profitRate = profitRate.sub(feePercentage);

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

    // #####################
    // # PRIVATE FUNCTIONS #
    // #####################

    /// @notice Lock a user
    /// @param  target_         The address of the user to lock
    function lock(address target_) private {

        locked[target_] = true;

    }


    function reckonAuction(uint id_) private {

        lock(models[id_].owner);
        lock(models[id_].topBidOwner);
        availableBalance = models[id_].topBidPrice.mul(feePercentage).div(100);
        balances[models[id_].owner] = models[id_].topBidPrice.mul(profitRate).div(100);
        balances[models[id_].topBidOwner] =
                balances[models[id_].topBidOwner].sub(models[id_].topBidPrice);
        lockedBalances[models[id_].topBidOwner] =
            lockedBalances[models[id_].topBidOwner].sub(models[id_].topBidPrice);
        address _previousOwner = models[id_].owner;
        models[id_].auctionState = 0;
        models[id_].owner = models[id_].topBidOwner;
        models[id_].ownerSince = block.timestamp;
        models[id_].topBidOwner = address(0);
        models[id_].topBidPrice = 0;
        unlock(_previousOwner);
        unlock(models[id_].owner);
        emit ModelNewOwner(id_, _previousOwner, models[id_].owner,
                           models[id_].ownerSince);

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

        require(models[id_].auctionState == 3 || (models[id_].auctionState == 4
                    && models[id_].auctionLimit > block.timestamp),
                'Taking bids for this model is not available.');
        _;

    }

    /// @notice Verifies whether the model is for rent
    /// @param  id_             Id of the model to verify
    modifier onlyModelForRent(uint id_) {

        require(models[id_].rentState == 2,
                'Renting this model is not available.');
        _;

    }

    /// @notice Verifies whether the model is for sale
    /// @param  id_             Id of the model to verify
    modifier onlyModelForSale(uint id_) {

        require(models[id_].auctionState == 2,
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
        uint8 auctionState;
        uint256 sellPrice;
        uint256 auctionLimit;
        address topBidOwner;
        uint256 topBidPrice;
        uint8 rentState;
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

    uint256 constant private DEFAULT_FEE_PERCENTAGE = 10;
    uint256 constant private DEFAULT_FEEDBACK_PRICE = 1e18; // 1 XRP

    // #########
    // # ENUMS #
    // #########

    // ####################
    // # PUBLIC VARIABLES #
    // ####################

    // #####################
    // # PRIVATE VARIABLES #
    // #####################

    uint256 private feePercentage;
    uint256 private feedbackPrice;
    uint256 private profitRate;

    mapping(address => uint256) private balances;
    mapping(address => bool) private locked;
    mapping(address => uint256) private lockedBalances;
    Model[] private models;
    ProofOfRental[] private proofOfRentals;

    // ##########
    // # EVENTS #
    // ##########

    event ModelNewOwner(uint modelId_, address previousOwner_, address newOwner_, uint256 timestamp_);
    event ModelNewRent(uint modelId_, uint proofId_, address renter_, uint256 timestamp_);
    event Withdraw(address owner_, uint256 amount_);

 }