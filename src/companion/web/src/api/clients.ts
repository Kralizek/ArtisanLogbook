import { ApolloClient, HttpLink, InMemoryCache } from "@apollo/client";
import createClient from "openapi-fetch";
import type { paths } from "./generated";

export const clientHeaders = { "X-Artisan-Logbook-Client": "web" };

export const historyClient = new ApolloClient({
  link: new HttpLink({
    uri: "/graphql",
    headers: clientHeaders,
    credentials: "omit",
    useGETForQueries: false,
  }),
  cache: new InMemoryCache(),
});

export const operationsClient = createClient<paths>({
  baseUrl: "",
  headers: clientHeaders,
  credentials: "omit",
});
