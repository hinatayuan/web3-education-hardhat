// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./YDToken.sol";

contract CourseManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    IERC20 public immutable ydToken;
    
    uint256 public constant FEE_RATE = 500; // 5% fee (500/10000)
    uint256 public constant EXCHANGE_RATE = 4000; // 1 ETH = 4000 YD tokens
    
    // Exchange reserves
    uint256 public ethReserve;
    uint256 public tokenReserve;
    
    // Default reserves configuration
    uint256 public constant DEFAULT_TOKEN_RESERVE = 1000000 * 10**18; // 100万 YD tokens
    uint256 public constant DEFAULT_ETH_RESERVE = 0.05 ether; // 0.05 ETH (可兑换200个YD)
    
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
    
    event TokensPurchased(address indexed buyer, uint256 ethAmount, uint256 tokenAmount);
    event TokensSold(address indexed seller, uint256 tokenAmount, uint256 ethAmount);
    event ETHReserveAdded(uint256 amount);
    event TokenReserveAdded(uint256 amount);
    event ReservesInitialized(uint256 tokenReserve, uint256 ethReserve);
    
    constructor(address _ydToken, address initialOwner) 
        payable
        Ownable(initialOwner)
    {
        require(_ydToken != address(0), "Invalid YD token address");
        require(msg.value >= DEFAULT_ETH_RESERVE, "Insufficient ETH for reserves");
        
        ydToken = IERC20(_ydToken);
        
        // 初始化储备（token储备将通过initializeTokenReserve函数设置）
        ethReserve = DEFAULT_ETH_RESERVE;
        
        emit ReservesInitialized(0, DEFAULT_ETH_RESERVE);
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
    
    // ETH <-> YD token exchange functions
    function buyTokens() external payable nonReentrant {
        require(msg.value > 0, "Must send ETH to buy tokens");
        require(tokenReserve > 0, "Token reserve not initialized");
        
        uint256 tokenAmount = msg.value * EXCHANGE_RATE;
        
        require(tokenAmount % 1e18 == 0, "Token amount must be divisible by 1e18");
        require(tokenReserve >= tokenAmount, "Insufficient token reserve");
        
        // Update reserves
        ethReserve += msg.value;
        tokenReserve -= tokenAmount;
        
        // Transfer tokens to buyer
        ydToken.safeTransfer(msg.sender, tokenAmount);
        
        emit TokensPurchased(msg.sender, msg.value, tokenAmount);
    }
    
    function sellTokens(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "Token amount must be greater than 0");
        require(tokenAmount % EXCHANGE_RATE == 0, "Token amount must be divisible by exchange rate");
        
        uint256 ethAmount = tokenAmount / EXCHANGE_RATE;
        require(ethReserve >= ethAmount, "Insufficient ETH reserve");
        
        // Transfer tokens from seller
        ydToken.safeTransferFrom(msg.sender, address(this), tokenAmount);
        
        // Update reserves
        ethReserve -= ethAmount;
        tokenReserve += tokenAmount;
        
        // Transfer ETH to seller
        payable(msg.sender).transfer(ethAmount);
        
        emit TokensSold(msg.sender, tokenAmount, ethAmount);
    }
    
    // Admin functions
    function addETHReserve() external payable onlyOwner {
        require(msg.value > 0, "Must send ETH");
        ethReserve += msg.value;
        emit ETHReserveAdded(msg.value);
    }
    
    function addTokenReserve(uint256 amount) external onlyOwner {
        ydToken.safeTransferFrom(msg.sender, address(this), amount);
        tokenReserve += amount;
        emit TokenReserveAdded(amount);
    }
    
    function mintTokenReserve(uint256 amount) external onlyOwner {
        YDToken(address(ydToken)).mint(address(this), amount);
        tokenReserve += amount;
        emit TokenReserveAdded(amount);
    }
    
    // 初始化token储备（仅在部署后调用一次）
    function initializeTokenReserve() external onlyOwner {
        require(tokenReserve == 0, "Token reserve already initialized");
        YDToken(address(ydToken)).mint(address(this), DEFAULT_TOKEN_RESERVE);
        tokenReserve = DEFAULT_TOKEN_RESERVE;
        emit TokenReserveAdded(DEFAULT_TOKEN_RESERVE);
    }
    
    // 设置token储备数量（用于部署脚本）
    function setTokenReserve(uint256 amount) external onlyOwner {
        require(tokenReserve == 0, "Token reserve already initialized");
        tokenReserve = amount;
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
    
    function getExchangeReserves() external view returns (uint256 _ethReserve, uint256 _tokenReserve) {
        return (ethReserve, tokenReserve);
    }
    
    // Calculate token amount for given ETH
    function calculateTokensForETH(uint256 ethAmount) external pure returns (uint256) {
        return ethAmount * EXCHANGE_RATE;
    }
    
    // Calculate ETH amount for given tokens
    function calculateETHForTokens(uint256 tokenAmount) external pure returns (uint256) {
        return tokenAmount / EXCHANGE_RATE;
    }
    
    // Receive ETH and auto-add to reserve if from owner
    receive() external payable {
        if (msg.sender == owner()) {
            ethReserve += msg.value;
            emit ETHReserveAdded(msg.value);
        }
    }
}