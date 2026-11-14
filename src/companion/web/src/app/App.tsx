import { useState } from "react";
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
  useMantineColorScheme,
} from "@mantine/core";
import { Link, Route, Routes, useLocation } from "react-router";
import { useStatus } from "../api/status";
import { Home } from "../pages/Home";
import { RecentCrafts } from "../pages/RecentCrafts";

export function App() {
  const [opened, setOpened] = useState(false);
  const { toggleColorScheme } = useMantineColorScheme();
  const location = useLocation();
  const state = useStatus();
  return (
    <AppShell
      header={{ height: 64 }}
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
            <Text fw={700}>
              Artisan Logbook{" "}
              <Text component="span" fw={400} c="dimmed">
                Companion
              </Text>
            </Text>
          </Group>
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
        <NavLink
          component={Link}
          to="/"
          label="Overview"
          active={location.pathname === "/"}
          onClick={() => setOpened(false)}
        />
        <NavLink
          component={Link}
          to="/history"
          label="Recent crafts"
          active={location.pathname === "/history"}
          onClick={() => setOpened(false)}
        />
      </AppShell.Navbar>
      <AppShell.Main>
        <div className="content">
          <Routes>
            <Route path="/" element={<Home state={state} />} />
            <Route path="/history" element={<RecentCrafts />} />
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
