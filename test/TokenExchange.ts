import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.connect();

describe("TokenExchange", function () {
    let ydToken: any;
    let courseManager: any;
    let owner: any;
    let user1: any;
    let user2: any;

    beforeEach(async function () {
        [owner, user1, user2] = await ethers.getSigners();

        ydToken = await ethers.deployContract("YDToken", [owner.address]);
        courseManager = await ethers.deployContract("CourseManager", [await ydToken.getAddress(), owner.address]);

        const reserveAmount = ethers.parseEther("100000");
        await ydToken.mint(owner.address, reserveAmount);
        await ydToken.approve(await courseManager.getAddress(), reserveAmount);
        await courseManager.addTokenReserve(reserveAmount);
    });

    describe("Token Exchange", function () {
        it("应该能够用ETH购买YDToken (1 ETH = 4000 YDT)", async function () {
            const ethAmount = ethers.parseEther("1");
            const expectedTokenAmount = ethAmount * 4000n;

            await expect(courseManager.connect(user1).buyTokens({ value: ethAmount }))
                .to.emit(courseManager, "TokensPurchased")
                .withArgs(user1.address, ethAmount, expectedTokenAmount);

            const balance = await ydToken.balanceOf(user1.address);
            expect(balance).to.equal(expectedTokenAmount);
        });

        it("应该能够卖出YDToken换取ETH", async function () {
            const ethAmount = ethers.parseEther("1");
            await courseManager.connect(user1).buyTokens({ value: ethAmount });

            const tokenAmount = ethers.parseEther("4000");
            await ydToken.connect(user1).approve(await courseManager.getAddress(), tokenAmount);

            const initialBalance = await ethers.provider.getBalance(user1.address);
            
            const tx = await courseManager.connect(user1).sellTokens(tokenAmount);
            const receipt = await tx.wait();
            const gasUsed = receipt!.gasUsed * receipt!.gasPrice;

            const finalBalance = await ethers.provider.getBalance(user1.address);
            const expectedBalance = initialBalance + ethAmount - gasUsed;

            expect(finalBalance).to.be.closeTo(expectedBalance, ethers.parseEther("0.01"));
        });

        it("购买代币时应该检查代币储备", async function () {
            const largeEthAmount = ethers.parseEther("1000");
            
            await expect(courseManager.connect(user1).buyTokens({ value: largeEthAmount }))
                .to.be.revertedWith("Insufficient token reserve");
        });

        it("卖出代币时应该检查ETH储备", async function () {
            await courseManager.connect(user1).buyTokens({ value: ethers.parseEther("1") });
            
            const tokenAmount = ethers.parseEther("8000");
            await ydToken.connect(user1).approve(await courseManager.getAddress(), tokenAmount);
            
            await expect(courseManager.connect(user1).sellTokens(tokenAmount))
                .to.be.revertedWith("Insufficient ETH reserve");
        });

        it("只有owner可以添加代币储备", async function () {
            const amount = ethers.parseEther("1000");
            await ydToken.mint(user1.address, amount);
            await ydToken.connect(user1).approve(await courseManager.getAddress(), amount);
            
            await expect(courseManager.connect(user1).addTokenReserve(amount))
                .to.be.revertedWithCustomError(courseManager, "OwnableUnauthorizedAccount");
        });

        it("应该能够正确显示合约余额", async function () {
            const ethAmount = ethers.parseEther("2");
            const initialTokenBalance = await ydToken.balanceOf(await courseManager.getAddress());
            
            await courseManager.connect(user1).buyTokens({ value: ethAmount });

            const [ethBalance, tokenBalance] = await courseManager.getContractBalances();
            expect(ethBalance).to.equal(ethAmount);
            expect(tokenBalance).to.equal(initialTokenBalance - (ethAmount * 4000n));
        });

        it("应该能处理直接转入的代币", async function () {
            const directTransferAmount = ethers.parseEther("1000");
            
            await ydToken.mint(user1.address, directTransferAmount);
            await ydToken.connect(user1).transfer(await courseManager.getAddress(), directTransferAmount);
            
            const ethAmount = ethers.parseEther("1");
            const expectedTokenAmount = ethAmount * 4000n;
            
            await expect(courseManager.connect(user2).buyTokens({ value: ethAmount }))
                .to.emit(courseManager, "TokensPurchased")
                .withArgs(user2.address, ethAmount, expectedTokenAmount);

            const balance = await ydToken.balanceOf(user2.address);
            expect(balance).to.equal(expectedTokenAmount);
        });
    });
});