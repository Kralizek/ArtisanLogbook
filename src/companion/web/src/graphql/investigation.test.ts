import { addTypenameToDocument } from "@apollo/client/utilities";
import { visit } from "graphql";
import { expect, it } from "vitest";
import {
  ActivityInvestigationDocument,
  InvestigationCraftDocument,
  InvestigationCraftsDocument,
  InvestigationSignatureDocument,
  ItemInvestigationDocument,
  RecipeConfigurationsDocument,
  RecipeInvestigationDocument,
} from "./generated/graphql";

it("keeps every C12 request within the API's 100-field parser limit after Apollo transforms", () => {
  for (const [name, document] of Object.entries({
    ActivityInvestigationDocument,
    RecipeInvestigationDocument,
    RecipeConfigurationsDocument,
    ItemInvestigationDocument,
    InvestigationSignatureDocument,
    InvestigationCraftsDocument,
    InvestigationCraftDocument,
  })) {
    let fields = 0;
    visit(addTypenameToDocument(document), {
      Field: () => {
        fields++;
      },
    });
    expect(fields, `${name} sends ${fields} fields`).toBeLessThanOrEqual(100);
  }
});
