import { Bytes, ethereum, store } from "@graphprotocol/graph-ts";
import {
  Canceled as CanceledEvent,
  Deposited as DepositedEvent,
  Withdrawn as WithdrawnEvent,
} from "../generated/DepositTimelock/DepositTimelock";
import {
  Canceled as CanceledEntity,
  Deposited as DepositedEntity,
  Deposit as DepositEntity,
  DepositTimelockEvent as DepositTimelockEventEntity,
  Withdrawn as WithdrawnEntity,
} from "../generated/schema";
import { createERC20Token } from "./utils";

class DepositTimelockEventType {
  static Deposited: string = "Deposited";
  static Canceled: string = "Canceled";
  static Withdrawn: string = "Withdrawn";
}

function getId(event: ethereum.Event): Bytes {
  return event.transaction.hash.concatI32(event.logIndex.toI32());
}

function createDepositTimelockEventEntity(
  event: ethereum.Event,
  loanTermsHash: Bytes,
  type: string,
): DepositTimelockEventEntity {
  const id = getId(event);

  const depositTimelockEventEntity = new DepositTimelockEventEntity(id);
  depositTimelockEventEntity.txHash = event.transaction.hash;
  depositTimelockEventEntity.timestamp = event.block.timestamp;
  depositTimelockEventEntity.loanTermsHash = loanTermsHash;
  depositTimelockEventEntity.type = type;

  if (type === DepositTimelockEventType.Deposited) {
    depositTimelockEventEntity.deposited = id;
  } else if (type === DepositTimelockEventType.Canceled) {
    depositTimelockEventEntity.canceled = id;
  } else if (type === DepositTimelockEventType.Withdrawn) {
    depositTimelockEventEntity.withdrawn = id;
  }

  depositTimelockEventEntity.save();

  return depositTimelockEventEntity;
}

export function handleDeposited(event: DepositedEvent): void {
  createERC20Token(event.params.token);

  const depositEntity = new DepositEntity(event.params.depositor.concat(event.params.context));
  depositEntity.depositor = event.params.depositor;
  depositEntity.target = event.params.target;
  depositEntity.context = event.params.context;
  depositEntity.token = event.params.token;
  depositEntity.amount = event.params.amount;
  depositEntity.expiration = event.params.expiration;
  depositEntity.save();

  const depositTimelockEventEntity = createDepositTimelockEventEntity(
    event,
    event.params.context,
    DepositTimelockEventType.Deposited,
  );

  const depositedEntity = new DepositedEntity(depositTimelockEventEntity.id);
  depositedEntity.depositor = event.params.depositor;
  depositedEntity.target = event.params.target;
  depositedEntity.context = event.params.context;
  depositedEntity.token = event.params.token;
  depositedEntity.amount = event.params.amount;
  depositedEntity.expiration = event.params.expiration;
  depositedEntity.save();
}

export function handleCanceled(event: CanceledEvent): void {
  store.remove("Deposit", event.params.depositor.concat(event.params.context).toHexString());

  const depositTimelockEventEntity = createDepositTimelockEventEntity(
    event,
    event.params.context,
    DepositTimelockEventType.Canceled,
  );

  const canceledEntity = new CanceledEntity(depositTimelockEventEntity.id);
  canceledEntity.depositor = event.params.depositor;
  canceledEntity.target = event.params.target;
  canceledEntity.context = event.params.context;
  canceledEntity.amount = event.params.amount;
  canceledEntity.save();
}

export function handleWithdrawn(event: WithdrawnEvent): void {
  createERC20Token(event.params.withdrawToken);

  store.remove("Deposit", event.params.depositor.concat(event.params.context).toHexString());

  const depositTimelockEventEntity = createDepositTimelockEventEntity(
    event,
    event.params.context,
    DepositTimelockEventType.Withdrawn,
  );

  const withdrawnEntity = new WithdrawnEntity(depositTimelockEventEntity.id);
  withdrawnEntity.depositor = event.params.depositor;
  withdrawnEntity.withdrawer = event.params.withdrawer;
  withdrawnEntity.context = event.params.context;
  withdrawnEntity.depositToken = event.params.depositToken;
  withdrawnEntity.withdrawToken = event.params.withdrawToken;
  withdrawnEntity.depositAmount = event.params.depositAmount;
  withdrawnEntity.withdrawAmount = event.params.withdrawAmount;
  withdrawnEntity.refundDepositAmount = event.params.refundDepositAmount;
  withdrawnEntity.refundWithdrawAmount = event.params.refundWithdrawAmount;
  withdrawnEntity.save();
}
