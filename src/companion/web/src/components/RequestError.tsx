import { CombinedGraphQLErrors, ServerError } from "@apollo/client/errors";
import { Alert, Button, Stack } from "@mantine/core";
import { OperationalError } from "../api/status";

function message(error: Error): string {
  if (CombinedGraphQLErrors.is(error)) {
    return error.errors.some((item) => !item.path)
      ? "The history request could not be validated. Check that the application and API versions agree."
      : "Some history could not be loaded. Available results are shown below.";
  }
  if (ServerError.is(error))
    return `The Companion rejected this request (HTTP ${error.statusCode}).`;
  if (error instanceof OperationalError)
    return `The Companion rejected this request (HTTP ${error.status}).`;
  return "The Companion is unavailable or the connection failed. Check that it is running, then retry.";
}

export function RequestError({
  error,
  retry,
}: {
  error: Error;
  retry: () => void;
}) {
  return (
    <Alert color="red" title="Unable to load data" role="alert">
      <Stack align="flex-start" gap="xs">
        {message(error)}
        <Button size="xs" variant="light" color="red" onClick={retry}>
          Retry
        </Button>
      </Stack>
    </Alert>
  );
}
