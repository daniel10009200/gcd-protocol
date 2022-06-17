const {
	expectEvent,
	ether
} = require('openzeppelin-test-helpers')
const BN = web3.utils.BN
const { expect } = require('chai')
const utils = require('./helpers/utils')

contract('CDPManager with wrapped assets', function([deployer]) {
	// deploy & initial settings
	beforeEach(async function() {
		this.utils = utils(this, 'curveLP')
		this.deployer = deployer
		await this.utils.deploy()
	});

	describe('Optimistic cases', function() {
		it('Should spawn a position', async function() {
			const mainAmount = ether('100');
			const gcdAmount = ether('20');

			const { logs } = await this.utils.join(this.wrappedAsset, mainAmount, gcdAmount);

			expectEvent.inLogs(logs, 'Join', {
				asset: this.wrappedAsset.address,
				owner: deployer,
				main: mainAmount,
				gcd: gcdAmount,
			});

			const assetAmountInPosition = await this.vault.collaterals(this.wrappedAsset.address, deployer);
			const gcdBalance = await this.gcd.balanceOf(deployer);

			expect(assetAmountInPosition).to.be.bignumber.equal(mainAmount);
			expect(gcdBalance).to.be.bignumber.equal(gcdAmount);
		})

		describe('Repay & withdraw', function() {
			it('Should repay the debt of a position and withdraw collaterals', async function() {
				const mainAmount = ether('100');
				const gcdAmount = ether('20');

				await this.utils.join(this.wrappedAsset, mainAmount, gcdAmount);

				const { logs } = await this.utils.repayAllAndWithdraw(this.wrappedAsset, deployer);

				expectEvent.inLogs(logs, 'Exit', {
					asset: this.wrappedAsset.address,
					owner: deployer,
					main: mainAmount,
					gcd: gcdAmount,
				});

				const mainAmountInPosition = await this.vault.collaterals(this.wrappedAsset.address, deployer);

				expect(mainAmountInPosition).to.be.bignumber.equal(new BN(0));
			})

			it('Should partially repay the debt of a position and withdraw the part of the collateral', async function() {
				const mainAmount = ether('100');
				const gcdAmount = ether('20');

				await this.utils.join(this.wrappedAsset, mainAmount, gcdAmount);

				const mainToWithdraw = ether('50');
				const gcdToWithdraw = ether('2.5');

				const { logs } = await this.utils.exit(this.wrappedAsset, mainToWithdraw, gcdToWithdraw);

				expectEvent.inLogs(logs, 'Exit', {
					asset: this.wrappedAsset.address,
					owner: deployer,
					main: mainToWithdraw,
					gcd: gcdToWithdraw,
				});

				const mainAmountInPosition = await this.vault.collaterals(this.wrappedAsset.address, deployer);
				const gcdInPosition = await this.vault.debts(this.wrappedAsset.address, deployer);

				expect(mainAmountInPosition).to.be.bignumber.equal(mainAmount.sub(mainToWithdraw));
				expect(gcdInPosition).to.be.bignumber.equal(gcdAmount.sub(gcdToWithdraw));
			})

		})

		it('Should deposit collaterals to position and mint GCD', async function() {
			let mainAmount = ether('100');
			let gcdAmount = ether('20');

			await this.utils.join(this.wrappedAsset, mainAmount, gcdAmount);

			const { logs } = await this.utils.join(this.wrappedAsset, mainAmount, gcdAmount);

			expectEvent.inLogs(logs, 'Join', {
				asset: this.wrappedAsset.address,
				owner: deployer,
				main: mainAmount,
				gcd: gcdAmount,
			});

			const mainAmountInPosition = await this.vault.collaterals(this.wrappedAsset.address, deployer);
			const gcdBalance = await this.gcd.balanceOf(deployer);

			expect(mainAmountInPosition).to.be.bignumber.equal(mainAmount.mul(new BN(2)));
			expect(gcdBalance).to.be.bignumber.equal(gcdAmount.mul(new BN(2)));
		})

		it('Should withdraw collateral from a position and repay (burn) GCD', async function() {
			let mainAmount = ether('100');
			let gcdAmount = ether('20');

			await this.utils.join(this.wrappedAsset, mainAmount.mul(new BN(2)), gcdAmount.mul(new BN(2)));

			const gcdSupplyBefore = await this.gcd.totalSupply();

			await this.utils.exit(this.wrappedAsset, mainAmount, gcdAmount);

			const gcdSupplyAfter = await this.gcd.totalSupply();

			const mainAmountInPosition = await this.vault.collaterals(this.wrappedAsset.address, deployer);
			const gcdBalance = await this.gcd.balanceOf(deployer);

			expect(mainAmountInPosition).to.be.bignumber.equal(mainAmount);
			expect(gcdBalance).to.be.bignumber.equal(gcdAmount);
			expect(gcdSupplyAfter).to.be.bignumber.equal(gcdSupplyBefore.sub(gcdAmount));
		})
	});

	describe('Pessimistic cases', function() {
		describe('Spawn', function() {

			it('Reverts non valuable tx', async function() {
				const mainAmount = ether('0');
				const gcdAmount = ether('0');

				await this.wrappedAsset.approve(this.vault.address, mainAmount);
				const tx = this.utils.join(
					this.wrappedAsset,
					mainAmount, // main
					gcdAmount,	// GCD
				);
				await this.utils.expectRevert(tx, "GCD Protocol: USELESS_TX");
			})

			describe('Reverts when collateralization is incorrect', function() {
				it('Not enough main collateral', async function() {
					let mainAmount = ether('0');
					const gcdAmount = ether('20');

					await this.wrappedAsset.approve(this.vault.address, mainAmount);
					const tx = this.utils.join(
						this.wrappedAsset,
						mainAmount, // main
						gcdAmount,	// GCD
					);
					await this.utils.expectRevert(tx, "GCD Protocol: UNDERCOLLATERALIZED");
				})

				it('Reverts when main collateral is not approved', async function() {
					const mainAmount = ether('100');
					const gcdAmount = ether('20');

					const tx = this.utils.join(
						this.wrappedAsset,
						mainAmount, // main
						gcdAmount,	// GCD
						{
							noApprove: true
						},
					);
					await this.utils.expectRevert(tx, "TRANSFER_FROM_FAILED");
				})
			})
		})

		describe('Exit', function() {
			it('Reverts non valuable tx', async function() {
				const mainAmount = ether('100');
				const gcdAmount = ether('20');

				await this.utils.join(this.wrappedAsset, mainAmount, gcdAmount);

				const tx = this.utils.exit(this.wrappedAsset, 0, 0, 0);
				await this.utils.expectRevert(tx, "GCD Protocol: USELESS_TX");
			})

			it('Reverts when position becomes undercollateralized', async function() {
				const mainAmount = ether('100');
				const gcdAmount = ether('20');

				await this.utils.join(this.wrappedAsset, mainAmount, gcdAmount);

				const tx = this.utils.exit(this.wrappedAsset, mainAmount, 0, 0);
				await this.utils.expectRevert(tx, "GCD Protocol: UNDERCOLLATERALIZED");
			})
		})
	})

});
