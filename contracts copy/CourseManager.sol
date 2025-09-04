// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./YDToken.sol";
import "./SharedReservePool.sol";

contract CourseManager is Ownable, ReentrancyGuard {
    IERC20 public immutable ydToken;
    SharedReservePool public immutable sharedReservePool;
    
    uint256 public constant FEE_RATE = 500; // 5% fee (500/10000)
    
    struct Course {
        string courseId;
        string title;
        string description;
        uint256 price;
        address creator;
        bool isActive;
        uint256 createdAt;
    }
    
    mapping(string => Course) public courses;
    mapping(string => mapping(address => bool)) public userCoursePurchases;
    mapping(address => uint256) public creatorEarnings;
    
    string[] public courseIds;
    
    event CourseCreated(
        string indexed courseId,
        string title,
        uint256 price,
        address creator
    );
    
    event CoursePurchased(
        string indexed courseId,
        address indexed buyer,
        uint256 price
    );
    
    event CourseUpdated(
        string indexed courseId,
        string title,
        string description,
        uint256 price
    );
    
    event CreatorEarningsWithdrawn(
        address indexed creator,
        uint256 amount
    );
    
    event FeeCollected(
        string indexed courseId,
        address indexed buyer,
        uint256 feeAmount
    );
    
    event ETHReserveAdded(uint256 amount);
    event TokenReserveAdded(uint256 amount);
    
    constructor(address _ydToken, address _sharedReservePool, address initialOwner) 
        Ownable(initialOwner)
    {
        require(_ydToken != address(0), "Invalid YD token address");
        require(_sharedReservePool != address(0), "Invalid shared reserve pool address");
        
        ydToken = IERC20(_ydToken);
        sharedReservePool = SharedReservePool(payable(_sharedReservePool));
    }
    
    // Course management functions
    function createCourse(
        string memory courseId,
        string memory title,
        string memory description,
        uint256 price
    ) external {
        require(bytes(courseId).length > 0, "Course ID cannot be empty");
        require(bytes(title).length > 0, "Title cannot be empty");
        require(price > 0, "Price must be greater than 0");
        require(bytes(courses[courseId].courseId).length == 0, "Course ID already exists");
        
        courses[courseId] = Course({
            courseId: courseId,
            title: title,
            description: description,
            price: price,
            creator: msg.sender,
            isActive: true,
            createdAt: block.timestamp
        });
        
        courseIds.push(courseId);
        
        emit CourseCreated(courseId, title, price, msg.sender);
    }
    
    function updateCourse(
        string memory courseId,
        string memory title,
        string memory description,
        uint256 price
    ) external {
        require(bytes(courses[courseId].courseId).length > 0, "Course does not exist");
        require(courses[courseId].creator == msg.sender, "Only creator can update");
        require(bytes(title).length > 0, "Title cannot be empty");
        require(price > 0, "Price must be greater than 0");
        
        courses[courseId].title = title;
        courses[courseId].description = description;
        courses[courseId].price = price;
        
        emit CourseUpdated(courseId, title, description, price);
    }
    
    function purchaseCourse(string memory courseId) external nonReentrant {
        require(bytes(courses[courseId].courseId).length > 0, "Course does not exist");
        require(courses[courseId].isActive, "Course is not active");
        require(!userCoursePurchases[courseId][msg.sender], "Already purchased");
        require(courses[courseId].creator != msg.sender, "Cannot buy your own course");
        
        Course memory course = courses[courseId];
        
        // Calculate fee and creator amount
        uint256 feeAmount = (course.price * FEE_RATE) / 10000;
        uint256 creatorAmount = course.price - feeAmount;
        
        // Transfer to creator
        require(
            ydToken.transferFrom(msg.sender, course.creator, creatorAmount),
            "Creator payment failed"
        );
        
        // Fee to contract
        require(
            ydToken.transferFrom(msg.sender, address(this), feeAmount),
            "Fee transfer failed"
        );
        
        userCoursePurchases[courseId][msg.sender] = true;
        
        emit CoursePurchased(courseId, msg.sender, course.price);
        emit FeeCollected(courseId, msg.sender, feeAmount);
    }
    
    function toggleCourseStatus(string memory courseId) external {
        require(bytes(courses[courseId].courseId).length > 0, "Course does not exist");
        require(courses[courseId].creator == msg.sender, "Only creator can toggle status");
        
        courses[courseId].isActive = !courses[courseId].isActive;
    }
    
    // ETH <-> YD token exchange functions using shared reserve pool
    function buyTokens() external payable nonReentrant {
        require(msg.value > 0, "Must send ETH to buy tokens");
        
        // Forward ETH to shared reserve pool
        (bool success,) = address(sharedReservePool).call{value: msg.value}(
            abi.encodeWithSignature("buyTokens(uint256,address)", msg.value, msg.sender)
        );
        require(success, "Buy tokens failed");
    }
    
    function sellTokens(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "Token amount must be greater than 0");
        
        // Transfer tokens from user to this contract first
        ydToken.transferFrom(msg.sender, address(this), tokenAmount);
        
        // Approve shared reserve pool to spend tokens
        ydToken.approve(address(sharedReservePool), tokenAmount);
        
        // Call shared reserve pool to sell tokens
        sharedReservePool.sellTokens(tokenAmount, msg.sender);
    }
    
    // Admin functions - simplified since using shared reserve pool
    function addETHReserveToPool() external payable onlyOwner {
        require(msg.value > 0, "Must send ETH");
        sharedReservePool.addETHReserve{value: msg.value}();
        emit ETHReserveAdded(msg.value);
    }
    
    function addTokenReserveToPool(uint256 amount) external onlyOwner {
        ydToken.transferFrom(msg.sender, address(sharedReservePool), amount);
        sharedReservePool.addTokenReserve(amount);
        emit TokenReserveAdded(amount);
    }
    
    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        payable(owner()).transfer(balance);
    }
    
    function withdrawFees() external onlyOwner {
        uint256 tokenBalance = ydToken.balanceOf(address(this));
        require(tokenBalance > 0, "No fees to withdraw");
        
        require(
            ydToken.transfer(owner(), tokenBalance),
            "Fee withdrawal failed"
        );
    }
    
    // View functions
    function hasUserPurchasedCourse(
        string memory courseId,
        address user
    ) external view returns (bool) {
        return userCoursePurchases[courseId][user];
    }
    
    function getCourse(string memory courseId) external view returns (
        string memory title,
        string memory description,
        uint256 price,
        address creator,
        bool isActive,
        uint256 createdAt
    ) {
        Course memory course = courses[courseId];
        return (
            course.title,
            course.description,
            course.price,
            course.creator,
            course.isActive,
            course.createdAt
        );
    }
    
    function getAllCourseIds() external view returns (string[] memory) {
        return courseIds;
    }
    
    function getUserPurchasedCourses(address user) external view returns (string[] memory) {
        string[] memory purchasedCourses = new string[](courseIds.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < courseIds.length; i++) {
            if (userCoursePurchases[courseIds[i]][user]) {
                purchasedCourses[count] = courseIds[i];
                count++;
            }
        }
        
        string[] memory result = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = purchasedCourses[i];
        }
        
        return result;
    }
    
    function getCreatorEarnings(address creator) external view returns (uint256) {
        return creatorEarnings[creator];
    }
    
    
    function getContractBalances() external view returns (uint256 ethBalance, uint256 tokenBalance) {
        return (address(this).balance, ydToken.balanceOf(address(this)));
    }
    
    function getExchangeReserves() external view returns (uint256 ethReserve, uint256 tokenReserve) {
        return sharedReservePool.getReserves();
    }
    
    // Receive ETH - simple implementation since using shared reserve
    receive() external payable {
        // Just accept ETH, owner can manually add to shared reserve pool if needed
    }
}