// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./YDToken.sol";

/**
 * @title CourseManager - 课程管理合约
 * @dev 这是一个综合性的课程管理和代币兑换合约
 * 主要功能包括：
 * 1. 课程的创建、更新、购买和管理
 * 2. ETH与YD代币之间的兑换功能
 * 3. 平台手续费收取
 * 4. 流动性储备管理
 */
contract CourseManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // YD代币合约地址
    IERC20 public immutable ydToken;
    
    // 平台手续费率：5% (500/10000)
    uint256 public constant FEE_RATE = 500;
    // 兑换汇率：1 ETH = 4000 YD代币
    uint256 public constant EXCHANGE_RATE = 4000;
    
    // 兑换流动性储备
    uint256 public ethReserve;    // ETH储备量
    uint256 public tokenReserve; // YD代币储备量
    
    // 默认储备配置
    uint256 public constant DEFAULT_TOKEN_RESERVE = 1000000 * 10**18; // 100万 YD代币
    uint256 public constant DEFAULT_ETH_RESERVE = 0.05 ether; // 0.05 ETH (可兑换200个YD)
    
    // 课程结构体
    struct Course {
        string courseId;    // 课程ID
        string title;       // 课程标题
        string description; // 课程描述
        uint256 price;      // 课程价格（YD代币）
        address creator;    // 课程创建者地址
        bool isActive;      // 课程是否激活
        uint256 createdAt;  // 创建时间戳
    }
    
    // 存储映射
    mapping(string => Course) public courses; // 课程ID => 课程信息
    mapping(string => mapping(address => bool)) public userCoursePurchases; // 课程ID => 用户地址 => 是否已购买
    mapping(address => uint256) public creatorEarnings; // 创建者地址 => 收益金额
    
    string[] public courseIds; // 所有课程ID数组
    
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
    
    /**
     * @dev 构造函数 - 初始化课程管理合约
     * @param _ydToken YD代币合约地址
     * @param initialOwner 合约初始所有者地址
     * 注意：部署时需要发送至少DEFAULT_ETH_RESERVE数量的ETH用于初始化流动性储备
     */
    constructor(address _ydToken, address initialOwner) 
        payable
        Ownable(initialOwner)
    {
        require(_ydToken != address(0), "Invalid YD token address");
        require(msg.value >= DEFAULT_ETH_RESERVE, "Insufficient ETH for reserves");
        
        ydToken = IERC20(_ydToken);
        
        // 初始化ETH储备（token储备将通过initializeTokenReserve函数设置）
        ethReserve = DEFAULT_ETH_RESERVE;
        
        emit ReservesInitialized(0, DEFAULT_ETH_RESERVE);
    }
    
    // ===== 课程管理功能 =====
    
    /**
     * @dev 创建新课程
     * @param courseId 唯一的课程ID
     * @param title 课程标题
     * @param description 课程描述
     * @param price 课程价格（以YD代币计价）
     */
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
    
    /**
     * @dev 购买课程
     * @param courseId 要购买的课程ID
     * 注意：用户需要预先授权足够的YD代币给此合约
     * 平台将收取5%的手续费，剩余95%支付给课程创建者
     */
    function purchaseCourse(string memory courseId) external nonReentrant {
        require(bytes(courses[courseId].courseId).length > 0, "Course does not exist");
        require(courses[courseId].isActive, "Course is not active");
        require(!userCoursePurchases[courseId][msg.sender], "Already purchased");
        require(courses[courseId].creator != msg.sender, "Cannot buy your own course");
        
        Course memory course = courses[courseId];
        
        // 计算手续费和创建者收益
        uint256 feeAmount = (course.price * FEE_RATE) / 10000;  // 5%手续费
        uint256 creatorAmount = course.price - feeAmount;        // 95%给创建者
        
        // 向创建者支付代币
        require(
            ydToken.transferFrom(msg.sender, course.creator, creatorAmount),
            "Creator payment failed"
        );
        
        // 平台手续费转入合约
        require(
            ydToken.transferFrom(msg.sender, address(this), feeAmount),
            "Fee transfer failed"
        );
        
        // 记录用户已购买此课程
        userCoursePurchases[courseId][msg.sender] = true;
        
        emit CoursePurchased(courseId, msg.sender, course.price);
        emit FeeCollected(courseId, msg.sender, feeAmount);
    }
    
    function toggleCourseStatus(string memory courseId) external {
        require(bytes(courses[courseId].courseId).length > 0, "Course does not exist");
        require(courses[courseId].creator == msg.sender, "Only creator can toggle status");
        
        courses[courseId].isActive = !courses[courseId].isActive;
    }
    
    // ===== ETH <-> YD 代币兑换功能 =====
    
    /**
     * @dev 使用ETH购买YD代币
     * 汇率：1 ETH = 4000 YD代币
     * 用户发送ETH到合约，合约从自己的代币储备中转移YD代币给用户
     */
    function buyTokens() external payable nonReentrant {
        require(msg.value > 0, "Must send ETH to buy tokens");
        require(tokenReserve > 0, "Token reserve not initialized");
        
        // 按固定汇率计算可购买的代币数量
        uint256 tokenAmount = msg.value * EXCHANGE_RATE;
        
        require(tokenAmount % 1e18 == 0, "Token amount must be divisible by 1e18");
        require(tokenReserve >= tokenAmount, "Insufficient token reserve");
        
        // 更新储备
        ethReserve += msg.value;     // 增加ETH储备
        tokenReserve -= tokenAmount; // 减少代币储备
        
        // 向购买者转移代币
        ydToken.safeTransfer(msg.sender, tokenAmount);
        
        emit TokensPurchased(msg.sender, msg.value, tokenAmount);
    }
    
    /**
     * @dev 出售YD代币获取ETH
     * @param tokenAmount 要出售的YD代币数量
     * 汇率：4000 YD代币 = 1 ETH
     * 用户需要预先授权YD代币给此合约
     */
    function sellTokens(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "Token amount must be greater than 0");
        require(tokenAmount % EXCHANGE_RATE == 0, "Token amount must be divisible by exchange rate");
        
        // 按固定汇率计算可获得的ETH数量
        uint256 ethAmount = tokenAmount / EXCHANGE_RATE;
        require(ethReserve >= ethAmount, "Insufficient ETH reserve");
        
        // 从卖家转移代币到合约
        ydToken.safeTransferFrom(msg.sender, address(this), tokenAmount);
        
        // 更新储备
        ethReserve -= ethAmount;      // 减少ETH储备
        tokenReserve += tokenAmount;  // 增加代币储备
        
        // 向卖家转移ETH
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