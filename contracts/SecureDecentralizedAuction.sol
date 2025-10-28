// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title SecureDecentralizedAuction
 * @dev Production-ready auction platform with advanced security patterns
 */

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract SecureDecentralizedAuction is ReentrancyGuard, Ownable, Pausable {
    
    // ============ State Variables ============
    
    struct Auction {
        address payable seller;
        string itemName;
        string itemDescription;
        uint256 startingPrice;
        uint256 highestBid;
        address payable highestBidder;
        uint256 auctionEndTime;
        uint256 commitDeadline;
        uint256 revealDeadline;
        bool ended;
        bool cancelled;
    }
    
    struct Bid {
        bytes32 commitHash;
        uint256 value;
        bool revealed;
        bool withdrawn;
    }
    
    // Auction tracking
    uint256 public auctionCount;
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => mapping(address => Bid)) public bids;
    mapping(uint256 => address[]) public auctionBidders;
    
    // Platform fees
    uint256 public platformFeePercent = 2;
    uint256 public totalFeesCollected;
    
    // Constants
    uint256 constant MIN_BID_INCREMENT = 0.01 ether;
    uint256 constant MIN_AUCTION_DURATION = 1 hours;
    uint256 constant MAX_AUCTION_DURATION = 30 days;
    
    // ============ Events ============
    
    event AuctionCreated(
        uint256 indexed auctionId,
        address indexed seller,
        string itemName,
        uint256 startingPrice,
        uint256 commitDeadline,
        uint256 revealDeadline,
        uint256 auctionEndTime
    );
    
    event BidCommitted(uint256 indexed auctionId, address indexed bidder);
    event BidRevealed(uint256 indexed auctionId, address indexed bidder, uint256 value);
    event AuctionEnded(uint256 indexed auctionId, address indexed winner, uint256 winningBid);
    event AuctionCancelled(uint256 indexed auctionId);
    event BidWithdrawn(uint256 indexed auctionId, address indexed bidder, uint256 amount);
    event FeeWithdrawn(address indexed owner, uint256 amount);
    
    // ============ Modifiers ============
    
    modifier auctionExists(uint256 _auctionId) {
        require(_auctionId < auctionCount, "Auction does not exist");
        _;
    }
    
    modifier auctionNotEnded(uint256 _auctionId) {
        require(!auctions[_auctionId].ended, "Auction already ended");
        require(!auctions[_auctionId].cancelled, "Auction cancelled");
        _;
    }
    
    modifier onlyBeforeCommitDeadline(uint256 _auctionId) {
        require(block.timestamp < auctions[_auctionId].commitDeadline, "Commit phase ended");
        _;
    }
    
    modifier onlyAfterCommitDeadline(uint256 _auctionId) {
        require(block.timestamp >= auctions[_auctionId].commitDeadline, "Commit phase not ended");
        _;
    }
    
    modifier onlyBeforeRevealDeadline(uint256 _auctionId) {
        require(block.timestamp < auctions[_auctionId].revealDeadline, "Reveal phase ended");
        _;
    }
    
    modifier onlyAfterAuctionEnd(uint256 _auctionId) {
        require(block.timestamp >= auctions[_auctionId].auctionEndTime, "Auction not ended");
        _;
    }
    
    constructor() Ownable(msg.sender) {}
    
    // ============ Core Functions ============
    
    function createAuction(
        string memory _itemName,
        string memory _itemDescription,
        uint256 _startingPrice,
        uint256 _commitDuration,
        uint256 _revealDuration,
        uint256 _auctionDuration
    ) external whenNotPaused returns (uint256) {
        require(bytes(_itemName).length > 0, "Item name required");
        require(_startingPrice > 0, "Starting price must be greater than 0");
        require(
            _auctionDuration >= MIN_AUCTION_DURATION && 
            _auctionDuration <= MAX_AUCTION_DURATION,
            "Invalid auction duration"
        );
        require(_commitDuration > 0 && _revealDuration > 0, "Invalid phase durations");
        
        uint256 auctionId = auctionCount;
        uint256 commitDeadline = block.timestamp + _commitDuration;
        uint256 revealDeadline = commitDeadline + _revealDuration;
        uint256 auctionEndTime = revealDeadline + _auctionDuration;
        
        auctions[auctionId] = Auction({
            seller: payable(msg.sender),
            itemName: _itemName,
            itemDescription: _itemDescription,
            startingPrice: _startingPrice,
            highestBid: 0,
            highestBidder: payable(address(0)),
            auctionEndTime: auctionEndTime,
            commitDeadline: commitDeadline,
            revealDeadline: revealDeadline,
            ended: false,
            cancelled: false
        });
        
        emit AuctionCreated(
            auctionId,
            msg.sender,
            _itemName,
            _startingPrice,
            commitDeadline,
            revealDeadline,
            auctionEndTime
        );
        
        auctionCount++;
        return auctionId;
    }
    
    function commitBid(uint256 _auctionId, bytes32 _commitHash)
        external
        auctionExists(_auctionId)
        auctionNotEnded(_auctionId)
        onlyBeforeCommitDeadline(_auctionId)
        whenNotPaused
    {
        require(_commitHash != bytes32(0), "Invalid commit hash");
        require(bids[_auctionId][msg.sender].commitHash == bytes32(0), "Already committed");
        require(msg.sender != auctions[_auctionId].seller, "Seller cannot bid");
        
        bids[_auctionId][msg.sender] = Bid({
            commitHash: _commitHash,
            value: 0,
            revealed: false,
            withdrawn: false
        });
        
        auctionBidders[_auctionId].push(msg.sender);
        emit BidCommitted(_auctionId, msg.sender);
    }
    
    function revealBid(
        uint256 _auctionId,
        uint256 _value,
        bytes32 _salt
    )
        external
        payable
        auctionExists(_auctionId)
        auctionNotEnded(_auctionId)
        onlyAfterCommitDeadline(_auctionId)
        onlyBeforeRevealDeadline(_auctionId)
        whenNotPaused
        nonReentrant
    {
        Bid storage userBid = bids[_auctionId][msg.sender];
        Auction storage auction = auctions[_auctionId];
        
        require(!userBid.revealed, "Already revealed");
        require(userBid.commitHash != bytes32(0), "No commit found");
        require(
            userBid.commitHash == keccak256(abi.encodePacked(_value, _salt)),
            "Invalid reveal"
        );
        require(msg.value == _value, "Sent value must match bid value");
        require(_value >= auction.startingPrice, "Bid below starting price");
        
        userBid.value = _value;
        userBid.revealed = true;
        
        if (_value > auction.highestBid) {
            if (auction.highestBidder != address(0)) {
                bids[_auctionId][auction.highestBidder].withdrawn = false;
            }
            auction.highestBid = _value;
            auction.highestBidder = payable(msg.sender);
        }
        
        emit BidRevealed(_auctionId, msg.sender, _value);
    }
    
    function endAuction(uint256 _auctionId)
        external
        auctionExists(_auctionId)
        auctionNotEnded(_auctionId)
        onlyAfterAuctionEnd(_auctionId)
        whenNotPaused
        nonReentrant
    {
        Auction storage auction = auctions[_auctionId];
        
        require(
            msg.sender == auction.seller || msg.sender == owner(),
            "Only seller or owner can end"
        );
        
        auction.ended = true;
        
        if (auction.highestBidder != address(0)) {
            uint256 platformFee = (auction.highestBid * platformFeePercent) / 100;
            uint256 sellerAmount = auction.highestBid - platformFee;
            
            totalFeesCollected += platformFee;
            
            (bool successSeller, ) = auction.seller.call{value: sellerAmount}("");
            require(successSeller, "Transfer to seller failed");
            
            emit AuctionEnded(_auctionId, auction.highestBidder, auction.highestBid);
        } else {
            emit AuctionEnded(_auctionId, address(0), 0);
        }
    }
    
    function withdrawBid(uint256 _auctionId)
        external
        auctionExists(_auctionId)
        whenNotPaused
        nonReentrant
    {
        Bid storage userBid = bids[_auctionId][msg.sender];
        Auction storage auction = auctions[_auctionId];
        
        require(userBid.revealed, "Bid not revealed");
        require(!userBid.withdrawn, "Already withdrawn");
        require(
            msg.sender != auction.highestBidder || auction.ended,
            "Winner cannot withdraw before auction ends"
        );
        require(userBid.value > 0, "No bid to withdraw");
        
        uint256 amount = userBid.value;
        userBid.withdrawn = true;
        
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdrawal failed");
        
        emit BidWithdrawn(_auctionId, msg.sender, amount);
    }
    
    function cancelAuction(uint256 _auctionId)
        external
        auctionExists(_auctionId)
        auctionNotEnded(_auctionId)
        whenNotPaused
    {
        Auction storage auction = auctions[_auctionId];
        
        require(msg.sender == auction.seller, "Only seller can cancel");
        require(auctionBidders[_auctionId].length == 0, "Cannot cancel with bids");
        
        auction.cancelled = true;
        emit AuctionCancelled(_auctionId);
    }
    
    // ============ View Functions ============
    
    function getAuction(uint256 _auctionId)
        external
        view
        auctionExists(_auctionId)
        returns (
            address seller,
            string memory itemName,
            string memory itemDescription,
            uint256 startingPrice,
            uint256 highestBid,
            address highestBidder,
            uint256 auctionEndTime,
            bool ended,
            bool cancelled
        )
    {
        Auction storage auction = auctions[_auctionId];
        return (
            auction.seller,
            auction.itemName,
            auction.itemDescription,
            auction.startingPrice,
            auction.highestBid,
            auction.highestBidder,
            auction.auctionEndTime,
            auction.ended,
            auction.cancelled
        );
    }
    
    function getBid(uint256 _auctionId, address _bidder)
        external
        view
        returns (bytes32 commitHash, uint256 value, bool revealed, bool withdrawn)
    {
        Bid storage bid = bids[_auctionId][_bidder];
        return (bid.commitHash, bid.value, bid.revealed, bid.withdrawn);
    }
    
    function getAuctionBidders(uint256 _auctionId)
        external
        view
        returns (address[] memory)
    {
        return auctionBidders[_auctionId];
    }
    
    // ============ Admin Functions ============
    
    function withdrawFees()
        external
        onlyOwner
        nonReentrant
    {
        uint256 amount = totalFeesCollected;
        require(amount > 0, "No fees to withdraw");
        
        totalFeesCollected = 0;
        
        (bool success, ) = payable(owner()).call{value: amount}("");
        require(success, "Fee withdrawal failed");
        
        emit FeeWithdrawn(owner(), amount);
    }
    
    function setPlatformFee(uint256 _newFeePercent)
        external
        onlyOwner
    {
        require(_newFeePercent <= 10, "Fee too high (max 10%)");
        platformFeePercent = _newFeePercent;
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // ============ Helper Functions ============
    
    function generateCommitHash(uint256 _value, bytes32 _salt)
        external
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_value, _salt));
    }
    
    receive() external payable {}
}
