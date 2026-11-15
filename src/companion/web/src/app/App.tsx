import { useEffect, useState } from "react";
import {
  AppShell,
  Badge,
  Burger,
  Button,
  Group,
  NavLink,
  Stack,
  Text,
  Title,
  Select,
  Loader,
  Alert,
  useMantineColorScheme,
} from "@mantine/core";
import {
  Link,
  Navigate,
  Route,
  Routes,
  useLocation,
  useNavigate,
} from "react-router";
import { useStatus } from "../api/status";
import { useManagement } from "../api/management";
import { Companion } from "../pages/Companion";
import { ContextSearch } from "../components/ContextSearch";
import { RequestError } from "../components/RequestError";
import {
  rememberGame,
  rememberedGame,
  resolveGame,
  useGame,
  type ActiveGame,
} from "./game";
import { Investigation } from "../pages/Investigation";
import {
  EntityPreferencesProvider,
  Library,
  SavedInvestigationEntry,
} from "../organization";

export function App() {
  const [opened, setOpened] = useState(false);
  const { toggleColorScheme } = useMantineColorScheme();
  const location = useLocation();
  const navigate = useNavigate();
  const state = useStatus();
  const management = useManagement();
  const [startup] = useState(rememberedGame);
  const [lastAnalysis, setLastAnalysis] = useState<string>();
  const [lastLocator, setLastLocator] = useState<string>();
  const [baseGames, setBaseGames] = useState<ActiveGame[]>([]);
  const [metadataError, setMetadataError] = useState(false);
  const routeContext = location.pathname.split("/")[1];
  const analytical =
    routeContext && !["companion", "saved", "history"].includes(routeContext);
  const locator = analytical ? routeContext : (lastLocator ?? startup);
  const context = useGame(locator);
  useEffect(() => {
    const controller = new AbortController();
    Promise.all([
      resolveGame("retail", controller.signal),
      resolveGame("forever", controller.signal),
    ]).then(
      (games) => {
        if (!controller.signal.aborted) setBaseGames(games);
      },
      () => {
        if (!controller.signal.aborted) setMetadataError(true);
      },
    );
    return () => controller.abort();
  }, []);
  const destination = location.pathname + location.search;
  if (
    analytical &&
    context.game &&
    (lastLocator !== context.game.canonicalId || lastAnalysis !== destination)
  ) {
    setLastLocator(context.game.canonicalId);
    setLastAnalysis(destination);
  }
  const games = [
    ...new Map(
      [
        ...baseGames,
        ...(state.status?.history?.gameContexts.map((g) => g.context) ?? []),
        ...(context.game ? [context.game] : []),
      ].map((game) => [game.canonicalId, game]),
    ).values(),
  ];
  const currentMonitoring = management.error
    ? "Collection status unavailable"
    : management.data?.monitoring.state;
  const latest = management.data?.imports.find(
    (operation) => operation.completedAt,
  );
  return (
    <AppShell
      header={{ height: 76 }}
      navbar={{ width: 220, breakpoint: "sm", collapsed: { mobile: !opened } }}
      padding="lg"
    >
      <AppShell.Header>
        <Group h="100%" px="lg" justify="space-between">
          <Group>
            <Burger
              opened={opened}
              onClick={() => setOpened(!opened)}
              hiddenFrom="sm"
              size="sm"
              aria-label="Toggle navigation"
            />
            <Text fw={700} className="shell-brand">
              Artisan Logbook{" "}
              <Text component="span" fw={400} c="dimmed">
                Companion
              </Text>
            </Text>
          </Group>
          <Select
            label="Active game"
            aria-label="Active game context"
            value={context.game?.canonicalId ?? null}
            placeholder="Choose a game"
            data={games.map((game) => ({
              value: game.canonicalId,
              label: game.displayName,
            }))}
            onChange={(value) => {
              const game = games.find((game) => game.canonicalId === value);
              if (game) {
                const activity = `/${game.routeAlias}/activity?period=90`;
                if (location.pathname === "/companion") {
                  rememberGame(game.canonicalId);
                  setLastLocator(game.canonicalId);
                  setLastAnalysis(activity);
                } else navigate(activity);
              }
            }}
            w={170}
          />
          {context.game && (
            <ContextSearch key={context.game.canonicalId} game={context.game} />
          )}
          <Group gap="sm">
            <Badge variant="light" color={state.error ? "red" : "teal"}>
              {state.loading
                ? "Connecting"
                : state.error
                  ? "Unavailable"
                  : (state.status?.state ?? "Unavailable")}
            </Badge>
            <Button size="xs" variant="default" onClick={toggleColorScheme}>
              Light / dark
            </Button>
          </Group>
        </Group>
      </AppShell.Header>
      <AppShell.Navbar p="sm">
        <Text size="xs" c="dimmed" px="sm" mb="xs">
          INVESTIGATE
        </Text>
        <NavLink
          component={Link}
          to={
            context.game
              ? `/${context.game.routeAlias}/activity?period=90`
              : "/"
          }
          label="Activity & production"
          active={location.pathname.endsWith("/activity")}
          onClick={() => setOpened(false)}
        />
        {context.game && (
          <NavLink
            component={Link}
            to={`/${context.game.routeAlias}/library`}
            label="Your library"
            active={location.pathname.endsWith("/library")}
            onClick={() => setOpened(false)}
          />
        )}
        <Text size="xs" c="dimmed" px="sm" mt="xl" mb="xs">
          COLLECTION
        </Text>
        <NavLink
          component={Link}
          to="/companion"
          label="Companion"
          active={location.pathname === "/companion"}
          onClick={() => setOpened(false)}
        />
        {location.pathname === "/companion" && lastAnalysis && (
          <NavLink
            component={Link}
            to={lastAnalysis}
            label="Return to investigation"
          />
        )}
        <Stack gap={4} mt="auto" p="sm">
          <Text fw={600} size="sm">
            {currentMonitoring ?? "Checking collection…"}
          </Text>
          <Text c="dimmed" size="xs">
            {latest
              ? latest.outcome === "Successful"
                ? "Latest import succeeded"
                : "Latest import needs attention"
              : management.data
                ? "No import this session"
                : "Import status pending"}
          </Text>
          {context.game && (
            <Text size="xs">Investigating {context.game.displayName}</Text>
          )}
        </Stack>
      </AppShell.Navbar>
      <AppShell.Main>
        <div className="content">
          {metadataError && (
            <Alert color="yellow" mb="md">
              Game choices could not be loaded. Check the Companion connection
              and reload; existing context-qualified links remain usable.
            </Alert>
          )}
          <Routes>
            <Route
              path="/"
              element={
                context.game ? (
                  <Navigate
                    replace
                    to={`/${context.game.routeAlias}/activity?period=90`}
                  />
                ) : (
                  <Stack>
                    <Title>Explore your crafting history</Title>
                    <Text c="dimmed">
                      Choose a game from the selector above to investigate
                      production. Import and collection management are always
                      available.
                    </Text>
                    {context.loading && (
                      <Loader aria-label="Resolving remembered game" />
                    )}
                  </Stack>
                )
              }
            />
            <Route
              path="/history"
              element={
                context.game ? (
                  <Navigate
                    replace
                    to={`/${context.game.routeAlias}/crafts?period=all`}
                  />
                ) : (
                  <Navigate replace to="/" />
                )
              }
            />
            <Route
              path="/companion"
              element={<Companion state={management} contexts={games} />}
            />
            <Route path="/saved/:id" element={<SavedInvestigationEntry />} />
            <Route
              path="/:context/*"
              element={
                context.error ? (
                  <RequestError error={context.error} retry={context.retry} />
                ) : context.loading || !context.game ? (
                  <Loader aria-label="Resolving game context" />
                ) : (
                  <EntityPreferencesProvider
                    key={context.game.canonicalId}
                    game={context.game}
                  >
                    {!state.status?.applicationState.available &&
                      state.status && (
                        <Alert color="yellow" mb="md">
                          Personal organization is unavailable. History
                          investigations remain available; pins and saved
                          investigations cannot be loaded or saved.
                        </Alert>
                      )}
                    <Routes>
                      <Route
                        path="library"
                        element={<Library game={context.game} />}
                      />
                      <Route
                        path="activity"
                        element={
                          <Investigation game={context.game} kind="activity" />
                        }
                      />
                      <Route
                        path="recipes/:id"
                        element={
                          <Investigation game={context.game} kind="recipe" />
                        }
                      />
                      <Route
                        path="items/:id"
                        element={
                          <Investigation game={context.game} kind="item" />
                        }
                      />
                      <Route
                        path="crafts"
                        element={
                          <Investigation game={context.game} kind="crafts" />
                        }
                      />
                      <Route
                        path="crafts/:id"
                        element={
                          <Investigation game={context.game} kind="craft" />
                        }
                      />
                      <Route
                        path="*"
                        element={<Title>Investigation not found</Title>}
                      />
                    </Routes>
                  </EntityPreferencesProvider>
                )
              }
            />
            <Route
              path="*"
              element={
                <Stack>
                  <Title>Page not found</Title>
                  <Link to="/">Return to overview</Link>
                </Stack>
              }
            />
          </Routes>
        </div>
      </AppShell.Main>
    </AppShell>
  );
}
