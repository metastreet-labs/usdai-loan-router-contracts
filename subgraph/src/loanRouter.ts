import { Bytes, ethereum } from "@graphprotocol/graph-ts";
import {
  LoanCollateralLiquidated as LoanCollateralLiquidatedEvent,
  LoanLiquidated as LoanLiquidatedEvent,
  LoanOriginated as LoanOriginatedEvent,
  LoanRepaid as LoanRepaidEvent,
} from "../generated/LoanRouter/LoanRouter";
import {
  LoanCollateralLiquidated as LoanCollateralLiquidatedEntity,
  LoanLiquidated as LoanLiquidatedEntity,
  LoanOriginated as LoanOriginatedEntity,
  LoanRepaid as LoanRepaidEntity,
  LoanRouterEvent as LoanRouterEventEntity,
} from "../generated/schema";
import { createERC20Token } from "./utils";

class LoanRouterEventType {
  static LoanOriginated: string = "LoanOriginated";
  static LoanRepaid: string = "LoanRepaid";
  static LoanLiquidated: string = "LoanLiquidated";
  static LoanCollateralLiquidated: string = "LoanCollateralLiquidated";
}

function getId(event: ethereum.Event): Bytes {
  return event.transaction.hash.concatI32(event.logIndex.toI32());
}

function createLoanRouterEventEntity(event: ethereum.Event, loanTermsHash: Bytes, type: string): LoanRouterEventEntity {
  const id = getId(event);

  let loanRouterEventEntity = new LoanRouterEventEntity(id);
  loanRouterEventEntity.txHash = event.transaction.hash;
  loanRouterEventEntity.timestamp = event.block.timestamp;
  loanRouterEventEntity.loanTermsHash = loanTermsHash;
  loanRouterEventEntity.type = type;

  if (type === LoanRouterEventType.LoanOriginated) {
    loanRouterEventEntity.loanOriginated = id;
  } else if (type === LoanRouterEventType.LoanRepaid) {
    loanRouterEventEntity.loanRepaid = id;
  } else if (type === LoanRouterEventType.LoanLiquidated) {
    loanRouterEventEntity.loanLiquidated = id;
  } else if (type === LoanRouterEventType.LoanCollateralLiquidated) {
    loanRouterEventEntity.loanCollateralLiquidated = id;
  }

  loanRouterEventEntity.save();
  return loanRouterEventEntity;
}

export function handleLoanOriginated(event: LoanOriginatedEvent): void {
  createERC20Token(event.params.currencyToken);

  let loanRouterEventEntity = createLoanRouterEventEntity(
    event,
    event.params.loanTermsHash,
    LoanRouterEventType.LoanOriginated,
  );

  let loanOriginatedEntity = new LoanOriginatedEntity(loanRouterEventEntity.id);
  loanOriginatedEntity.loanTermsHash = event.params.loanTermsHash;
  loanOriginatedEntity.borrower = event.params.borrower;
  loanOriginatedEntity.currencyToken = event.params.currencyToken;
  loanOriginatedEntity.principal = event.params.principal;
  loanOriginatedEntity.originationFee = event.params.originationFee;
  loanOriginatedEntity.save();
}

export function handleLoanRepaid(event: LoanRepaidEvent): void {
  let loanRouterEventEntity = createLoanRouterEventEntity(
    event,
    event.params.loanTermsHash,
    LoanRouterEventType.LoanRepaid,
  );

  let loanRepaidEntity = new LoanRepaidEntity(loanRouterEventEntity.id);
  loanRepaidEntity.loanTermsHash = event.params.loanTermsHash;
  loanRepaidEntity.borrower = event.params.borrower;
  loanRepaidEntity.principal = event.params.principal;
  loanRepaidEntity.interest = event.params.interest;
  loanRepaidEntity.prepayment = event.params.prepayment;
  loanRepaidEntity.exitFee = event.params.exitFee;
  loanRepaidEntity.isRepaid = event.params.isRepaid;
  loanRepaidEntity.save();
}

export function handleLoanLiquidated(event: LoanLiquidatedEvent): void {
  let loanRouterEventEntity = createLoanRouterEventEntity(
    event,
    event.params.loanTermsHash,
    LoanRouterEventType.LoanLiquidated,
  );

  let loanLiquidatedEntity = new LoanLiquidatedEntity(loanRouterEventEntity.id);
  loanLiquidatedEntity.loanTermsHash = event.params.loanTermsHash;
  loanLiquidatedEntity.save();
}

export function handleLoanCollateralLiquidated(event: LoanCollateralLiquidatedEvent): void {
  let loanRouterEventEntity = createLoanRouterEventEntity(
    event,
    event.params.loanTermsHash,
    LoanRouterEventType.LoanCollateralLiquidated,
  );

  let loanCollateralLiquidatedEntity = new LoanCollateralLiquidatedEntity(loanRouterEventEntity.id);
  loanCollateralLiquidatedEntity.loanTermsHash = event.params.loanTermsHash;
  loanCollateralLiquidatedEntity.proceeds = event.params.proceeds;
  loanCollateralLiquidatedEntity.liquidationFee = event.params.liquidationFee;
  loanCollateralLiquidatedEntity.surplus = event.params.surplus;
  loanCollateralLiquidatedEntity.save();
}
