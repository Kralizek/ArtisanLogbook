import type { CodegenConfig } from "@graphql-codegen/cli";

const config: CodegenConfig = {
  schema: "../src/Runtime/GraphQL/schema.graphql",
  documents: ["src/graphql/*.graphql"],
  generates: {
    "src/graphql/generated/": {
      preset: "client",
      presetConfig: { fragmentMasking: false },
      config: {
        useTypeImports: true,
        strictScalars: true,
        scalars: { DateTime: "string", Long: "number", Decimal: "number" },
      },
    },
  },
};
export default config;
