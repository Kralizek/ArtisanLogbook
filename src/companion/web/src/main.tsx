import "@mantine/core/styles.css";
import "./styles/app.css";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { ApolloProvider } from "@apollo/client/react";
import { BrowserRouter } from "react-router";
import { historyClient } from "./api/clients";
import { App } from "./app/App";
import { theme } from "./app/theme";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <MantineProvider theme={theme} defaultColorScheme="auto">
      <ApolloProvider client={historyClient}>
        <BrowserRouter>
          <App />
        </BrowserRouter>
      </ApolloProvider>
    </MantineProvider>
  </StrictMode>,
);
