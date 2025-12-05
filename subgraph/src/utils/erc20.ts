import { Address } from "@graphprotocol/graph-ts";
import { IERC20Metadata as IERC20MetadataContract } from "../../generated/LoanRouter/IERC20Metadata";
import { ERC20Token as ERC20TokenEntity } from "../../generated/schema";

export function createERC20Token(address: Address): void {
  let erc20TokenEntity = ERC20TokenEntity.load(address);

  if (erc20TokenEntity == null) {
    const contract = IERC20MetadataContract.bind(address);

    erc20TokenEntity = new ERC20TokenEntity(address);

    const name = contract.try_name();
    erc20TokenEntity.name = name.reverted ? "" : name.value;

    const symbol = contract.try_symbol();
    erc20TokenEntity.symbol = symbol.reverted ? "" : symbol.value;

    const decimals = contract.try_decimals();
    erc20TokenEntity.decimals = decimals.reverted ? 18 : decimals.value;

    erc20TokenEntity.save();
  }
}
