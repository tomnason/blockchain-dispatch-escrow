# Dispatch Escrow Protocol
A trustless way to buy and sell tangible goods online. 
The protocol leverages a gated escrow system that aligns the release of buyer funds with verifiable actions performed by the seller, levelling the playing field and mitigating the risks buyers and sellers face today.

[![Overview video](http://img.youtube.com/vi/Xov_W_pMOY0/0.jpg)](http://www.youtube.com/watch?v=Xov_W_pMOY0 "Overview video")

## The problem 
While the purchase of goods online is nothing new, there is a real disconnect between the transfer of funds (risk) and the transfer of the physical goods (value). 
The buyer hands over all the money up front, then hopes that the seller processes, packs, and then organises handover to a carrier who then hopefully delivers the item.
The buyer bares all the risk with no control. 
## The solution
The smart contract based protocol leverages a gated escrow system that aligns the release of buyer funds with verifiable actions performed by the seller. 
* The buyer commits to the purchase pays full price to contract, but retains rights to funds if seller fails to deliver
* The seller earns the sale price incrementally at gates that map to the transfer goods in the real world
### Benefits
* Re-aligns incentives to keep sellers working for their money until the goods are delivered (encouraging better service)
* De-risks transactions with untrusted sellers
* Supports small sellers
* Decentralises and drives market competition
* Eliminates chargebacks for sellers
* Access to new customers
* Quality service can be rewarded
* Cuts out middlemen like paypal, credit card companies
* Cheaper/Faster
### Typical workflow
1.	Seller offers deal to buyer including;
    * Sale price
    * Fund release gates 1, 2, 3, in percentage form
    * Deadlines
2.	Buyer accepts offer by transferring the sale price to the contact.
3.	Seller provides tracking information and, if validated with the carrier, triggers gate 1.
4.	Seller hands over package to the carrier, who then updates the tracking status, triggering gate 2. The job is now considered in transit.
5.	Carrier delivers package, triggering gate 3 and the final release of the funds.

The seller can withdraw their earned value, based on the gates passed, at any time.

All validation of tracking information occurs via a Chainlink Oracle and underlying API.

###  Testing
Suggest opening the following in remix and deploying to Kovan
`https://github.com/tomnason/blockchain-dispatch-escrow/blob/master/contracts/DispatchEscrow.sol`

Remember to use two different accounts, one for the buyer and one for the seller.

Also remember to fund the contract with LINK prior to calling `requestBalanceUpdate()`.

Completed tracking code for use in `sellerAddTracking()`: `ppfmri9pbzlmq`

## Roadmap
* Flesh out team
* Improve carrier integration via Chainlink Adapters
* Deadline based incentives
* Merchant economics (possibly DAO model)
* Carrier economics (explore auctions)
* UI (buyer payment gateway, merchant dash)
* Batch withdrawals for retail
* Insurance
* Branding