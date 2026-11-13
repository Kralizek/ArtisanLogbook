import {
  ApolloClient,
  ApolloLink,
  InMemoryCache,
  Observable,
} from "@apollo/client";
import { ApolloProvider } from "@apollo/client/react";
import { MockedProvider } from "@apollo/client/testing/react";
import { MantineProvider } from "@mantine/core";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { GraphQLError } from "graphql";
import { RecentCraftsDocument } from "../graphql/generated/graphql";
import { RecentCrafts } from "./RecentCrafts";

const craft = {
  __typename: "Craft",
  id: "craft-one",
  recordedAt: "2026-01-02T00:00:00Z",
  concentrationSpent: null,
  character: { __typename: "Character", id: "opaque-character", name: null },
  recipe: {
    __typename: "Recipe",
    id: "recipe-one",
    name: null,
    blizzardId: 123,
  },
  profession: null,
};

describe("recent crafts", () => {
  it("fetches fresh history on revisits and explicitly refreshes the current page", async () => {
    const cache = new InMemoryCache();
    const result = (name: string) => ({
      crafts: {
        __typename: "CraftConnection",
        nodes: [{ ...craft, character: { ...craft.character, name } }],
        pageInfo: {
          __typename: "HistoryPageInfo",
          hasNextPage: false,
          endCursor: null,
        },
      },
    });
    cache.writeQuery({
      query: RecentCraftsDocument,
      data: result("Cached character"),
    });
    let name = "Imported character";
    const request = vi.fn(
      () =>
        new Observable<ApolloLink.Result>((observer) => {
          observer.next({ data: result(name) });
          observer.complete();
        }),
    );
    const client = new ApolloClient({ cache, link: new ApolloLink(request) });
    const page = (
      <MantineProvider>
        <ApolloProvider client={client}>
          <RecentCrafts />
        </ApolloProvider>
      </MantineProvider>
    );
    const first = render(page);
    expect(await screen.findByText("Imported character")).toBeInTheDocument();
    expect(request).toHaveBeenCalledTimes(1);
    name = "Refreshed character";
    await userEvent.click(screen.getByRole("button", { name: "Refresh" }));
    expect(await screen.findByText("Refreshed character")).toBeInTheDocument();
    expect(request).toHaveBeenCalledTimes(2);
    first.unmount();
    name = "New import after navigation";
    render(page);
    expect(
      await screen.findByText("New import after navigation"),
    ).toBeInTheDocument();
    expect(request).toHaveBeenCalledTimes(3);
    client.stop();
  });

  it("shows partial history with a redacted execution error", async () => {
    render(
      <MantineProvider>
        <MockedProvider
          mocks={[
            {
              request: { query: RecentCraftsDocument, variables: {} },
              result: {
                data: {
                  crafts: {
                    nodes: [craft],
                    pageInfo: { hasNextPage: false, endCursor: null },
                  },
                },
                errors: [
                  new GraphQLError("private execution detail", {
                    path: ["crafts", "nodes", 0, "profession"],
                  }),
                ],
              },
            },
          ]}
        >
          <RecentCrafts />
        </MockedProvider>
      </MantineProvider>,
    );
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Some history could not be loaded",
    );
    expect(screen.getByText("Recipe 123")).toBeInTheDocument();
    expect(
      screen.queryByText("private execution detail"),
    ).not.toBeInTheDocument();
  });

  it("distinguishes a validation failure", async () => {
    render(
      <MantineProvider>
        <MockedProvider
          mocks={[
            {
              request: { query: RecentCraftsDocument, variables: {} },
              result: {
                errors: [new GraphQLError("private validation detail")],
              },
            },
          ]}
        >
          <RecentCrafts />
        </MockedProvider>
      </MantineProvider>,
    );
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "could not be validated",
    );
    expect(
      screen.queryByText("private validation detail"),
    ).not.toBeInTheDocument();
  });

  it("renders unknown metadata without inventing values and follows forward cursors", async () => {
    render(
      <MantineProvider>
        <MockedProvider
          mocks={[
            {
              request: { query: RecentCraftsDocument, variables: {} },
              result: {
                data: {
                  crafts: {
                    nodes: [craft],
                    pageInfo: { hasNextPage: true, endCursor: "next" },
                  },
                },
              },
            },
            {
              request: {
                query: RecentCraftsDocument,
                variables: { after: "next" },
              },
              result: {
                data: {
                  crafts: {
                    nodes: [
                      {
                        ...craft,
                        id: "craft-two",
                        concentrationSpent: 0,
                        character: { ...craft.character, name: "Artisan" },
                      },
                    ],
                    pageInfo: { hasNextPage: false, endCursor: null },
                  },
                },
              },
            },
          ]}
        >
          <RecentCrafts />
        </MockedProvider>
      </MantineProvider>,
    );
    expect(screen.getByLabelText("Loading recent crafts")).toBeInTheDocument();
    expect(await screen.findByText("Recipe 123")).toBeInTheDocument();
    expect(screen.getByText("Unknown character")).toBeInTheDocument();
    expect(screen.queryByText(/opaque-character/)).not.toBeInTheDocument();
    expect(screen.getByText("Unknown profession")).toBeInTheDocument();
    expect(screen.getByText("Unknown")).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Next page" }));
    expect(await screen.findByText("Artisan")).toBeInTheDocument();
    expect(screen.getByText("0")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Next page" })).toBeDisabled();
  });

  it("handles empty history", async () => {
    render(
      <MantineProvider>
        <MockedProvider
          mocks={[
            {
              request: { query: RecentCraftsDocument, variables: {} },
              result: {
                data: {
                  crafts: {
                    nodes: [],
                    pageInfo: { hasNextPage: false, endCursor: null },
                  },
                },
              },
            },
          ]}
        >
          <RecentCrafts />
        </MockedProvider>
      </MantineProvider>,
    );
    expect(
      await screen.findByText("No recorded crafts yet."),
    ).toBeInTheDocument();
  });

  it("redacts a failed network request and offers retry", async () => {
    render(
      <MantineProvider>
        <MockedProvider
          mocks={[
            {
              request: { query: RecentCraftsDocument, variables: {} },
              error: new Error("private database filename"),
            },
          ]}
        >
          <RecentCrafts />
        </MockedProvider>
      </MantineProvider>,
    );
    expect(await screen.findByRole("alert")).toHaveTextContent(
      "Companion is unavailable",
    );
    expect(
      screen.queryByText("private database filename"),
    ).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Retry" })).toBeEnabled();
  });
});
