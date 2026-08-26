#include <stdio.h>
#include <stdlib.h>

#ifndef CODEX_EXIT_STATUS
#define CODEX_EXIT_STATUS 0
#endif

static const char *const observed_environment[] = {
    "SCHEDULED_RUN_DATE_ET",
    "SCHEDULED_RECOVERY_MODE",
    "SCHEDULED_AGENT_ENGINE",
    "SCHEDULED_SKILL_ROOT",
    "SCHEDULED_SKILL_LINK",
    "HOME",
    "PATH",
    "TZ",
    "TASK_ID",
    "WORKING_DIRECTORY",
    "CODEX",
    "CONTROLLED_PATH",
    "ENV_LOADER",
    "CODEX_HOME",
    "CODEX_MANAGED_PACKAGE_ROOT",
    "CODEX_MANAGED_BY_DIRECT",
    "CODEX_MANAGED_BY_NPM",
    "LANG",
    "LC_ALL",
    "REPO_VALUE",
    "DOTENV_COMMAND",
    "DOTENV_DOUBLE",
    "DOTENV_SINGLE",
    "DOTENV_ESCAPED",
    "DOTENV_BAD",
    "FATHOM_API_KEY",
    "SLACK_USER_TOKEN",
    "SLACK_BOT_TOKEN",
    "SLACK_APP_TOKEN",
    "LINEAR_API_KEY",
    "HUBSPOT_ACCESS_TOKEN",
    "PYLON_API_KEY",
    "NOTION_API_KEY",
    "DD_API_KEY",
    "DD_APP_KEY",
    "GOOGLE_CLIENT_ID",
    "GOOGLE_CLIENT_SECRET",
    "GOOGLE_REFRESH_TOKEN",
    "SKYVERN_API_KEY",
    "OPENAI_API_KEY",
    "CODEX_API_KEY",
    "PANGRAM_API_KEY",
    "USER",
    "USER_EMAIL",
    "SLACK_FORCE_BOT",
    "CINDER_SLACK_BOT_TOKEN",
    "CINDER_SLACK_APP_TOKEN",
    "CODEX_HOME_INPUT",
    "DYLD_INSERT_LIBRARIES",
    "DYLD_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH",
    "LD_PRELOAD",
    "LD_LIBRARY_PATH",
    "PYTHONPATH",
    "PYTHONHOME",
    "PYTHONSTARTUP",
    "PYTHONUSERBASE",
    "NODE_OPTIONS",
    "BASH_ENV",
    "ENV",
    "RUBYOPT",
    "PERL5OPT",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "ALL_PROXY",
    "NO_PROXY",
    "SSL_CERT_FILE",
    "SSL_CERT_DIR",
    "REQUESTS_CA_BUNDLE",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_SYSTEM",
    "GIT_SSH",
    "GIT_SSH_COMMAND",
    "GIT_EXEC_PATH",
    "SUPERSET_AGENT_ID",
    "CODEX_MANAGED_BY_EVIL",
};

static int write_arguments(int argc, char **argv) {
    FILE *file = fopen("codex.argv", "w");
    if (file == NULL) {
        return 1;
    }
    for (int index = 1; index < argc; ++index) {
        if (fprintf(file, "%s\n", argv[index]) < 0) {
            fclose(file);
            return 1;
        }
    }
    return fclose(file) == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    FILE *events = fopen("codex.events", "a");
    FILE *stdin_capture = fopen("codex.stdin", "wb");
    FILE *environment = fopen("codex.env", "w");
    if (events == NULL || stdin_capture == NULL || environment == NULL) {
        if (events != NULL) fclose(events);
        if (stdin_capture != NULL) fclose(stdin_capture);
        if (environment != NULL) fclose(environment);
        return 1;
    }
    fputs("native-codex\n", events);
    fclose(events);
    if (write_arguments(argc, argv) != 0) {
        fclose(stdin_capture);
        fclose(environment);
        return 1;
    }
    int character;
    while ((character = fgetc(stdin)) != EOF) {
        fputc(character, stdin_capture);
    }
    fclose(stdin_capture);
    for (size_t index = 0; index < sizeof(observed_environment) / sizeof(observed_environment[0]); ++index) {
        const char *name = observed_environment[index];
        const char *value = getenv(name);
        if (value != NULL) {
            fprintf(environment, "%s=%s\n", name, value);
        }
    }
    fclose(environment);
    return CODEX_EXIT_STATUS;
}
