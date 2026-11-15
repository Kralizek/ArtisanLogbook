import { ApolloClient, HttpLink, InMemoryCache } from "@apollo/client";
import createClient from "openapi-fetch";
import type { paths } from "./generated";

export const clientHeaders = { "X-Artisan-Logbook-Client": "web" };

export function createHistoryCache() {
  return new InMemoryCache({
    typePolicies: {
      AnalysisContributionGraph: { keyFields: false },
      AnalysisConfigurationGraph: { keyFields: false },
      RecipeAnalysisGraph: { keyFields: false },
    },
  });
}

export const historyClient = new ApolloClient({
  dataMasking: false,
  link: new HttpLink({
    uri: "/graphql",
    headers: clientHeaders,
    credentials: "omit",
    useGETForQueries: false,
  }),
  cache: createHistoryCache(),
});

export const operationsClient = createClient<paths>({
  baseUrl: "",
  headers: clientHeaders,
  credentials: "omit",
});
