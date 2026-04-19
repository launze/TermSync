package com.termsync.mobile.viewmodel

import kotlin.math.ln

enum class CommandCategory(val key: String, val label: String) {
    Ai("ai", "AI 助手"),
    Git("git", "Git"),
    Run("run", "运行"),
    Test("test", "测试"),
    HighRisk("high_risk", "高权限"),
    Custom("custom", "自定义");

    companion object {
        fun fromKey(key: String): CommandCategory {
            return entries.firstOrNull { it.key == key } ?: Custom
        }
    }
}

data class CommandShortcut(
    val id: String,
    val title: String,
    val command: String,
    val category: CommandCategory,
    val dangerous: Boolean = false,
    val builtIn: Boolean = false,
    val isFavorite: Boolean = false,
    val useCount: Int = 0,
    val lastUsedAt: Long = 0L,
    val createdAt: Long = 0L,
    val defaultRank: Int = 0
)

data class CommandShortcutSection(
    val key: String,
    val label: String,
    val commands: List<CommandShortcut>
)

data class CommandLibraryUiState(
    val recommended: List<CommandShortcut> = emptyList(),
    val favorites: List<CommandShortcut> = emptyList(),
    val recent: List<CommandShortcut> = emptyList(),
    val sections: List<CommandShortcutSection> = emptyList()
)

private val COMMAND_CATEGORY_ORDER = listOf(
    CommandCategory.Ai,
    CommandCategory.Git,
    CommandCategory.Run,
    CommandCategory.Test,
    CommandCategory.HighRisk,
    CommandCategory.Custom
)

fun normalizeCommandShortcutValue(value: String): String {
    return value
        .replace("\r", "\n")
        .lines()
        .map { it.trim() }
        .filter { it.isNotBlank() }
        .joinToString(" && ")
}

fun deriveCommandTitle(command: String): String {
    val normalized = normalizeCommandShortcutValue(command)
    if (normalized.isBlank()) return "自定义命令"
    val compact = normalized.replace(Regex("\\s+"), " ")
    return if (compact.length <= 28) compact else compact.take(27) + "…"
}

fun suggestCommandCategory(command: String): CommandCategory {
    val normalized = normalizeCommandShortcutValue(command)
    val lower = normalized.lowercase()
    return when {
        lower.isBlank() -> CommandCategory.Custom
        lower.startsWith("codex") ||
            lower.startsWith("claude") ||
            lower.startsWith("gemini") ||
            lower.startsWith("chatgpt") ||
            lower.startsWith("openai") -> CommandCategory.Ai
        lower == "git" || lower.startsWith("git ") -> CommandCategory.Git
        isDangerousCommand(normalized) -> CommandCategory.HighRisk
        lower.contains(" test") ||
            lower.startsWith("test") ||
            lower.contains("pytest") ||
            lower.contains("vitest") ||
            lower.contains("jest") ||
            lower.contains("cargo test") ||
            lower.contains("go test") -> CommandCategory.Test
        lower.startsWith("npm ") ||
            lower.startsWith("pnpm ") ||
            lower.startsWith("yarn ") ||
            lower.startsWith("bun ") ||
            lower.startsWith("cargo ") ||
            lower.startsWith("docker ") ||
            lower.startsWith("python ") ||
            lower.startsWith("uv ") ||
            lower.startsWith("make ") ||
            lower.startsWith("./") -> CommandCategory.Run
        else -> CommandCategory.Custom
    }
}

fun isDangerousCommand(command: String, category: CommandCategory? = null): Boolean {
    val normalized = normalizeCommandShortcutValue(command)
    val lower = normalized.lowercase()
    if (lower.isBlank()) return false
    if (category == CommandCategory.HighRisk) return true
    return listOf(
        "--dangerously",
        "--dangerous",
        "sudo ",
        "su -",
        " rm -rf",
        "rm -rf ",
        "remove-item -recurse -force",
        "del /f /s /q",
        "rd /s /q",
        "format ",
        "mkfs",
        "dd if=",
        "shutdown",
        "reboot",
        "halt",
        "docker system prune",
        "git clean -fd",
        "git reset --hard"
    ).any { marker -> lower.contains(marker) }
}

fun customCommandIdFor(command: String): String {
    val normalized = normalizeCommandShortcutValue(command)
    val hash = normalized.hashCode().toLong() and 0xffffffffL
    return "custom_${hash.toString(16)}"
}

fun createCustomCommandShortcut(
    command: String,
    title: String = deriveCommandTitle(command),
    category: CommandCategory = suggestCommandCategory(command),
    favorite: Boolean = false,
    useCount: Int = 0,
    lastUsedAt: Long = 0L,
    createdAt: Long = System.currentTimeMillis(),
    dangerous: Boolean = isDangerousCommand(command, category)
): CommandShortcut {
    val normalized = normalizeCommandShortcutValue(command)
    return CommandShortcut(
        id = customCommandIdFor(normalized),
        title = title,
        command = normalized,
        category = category,
        dangerous = dangerous,
        builtIn = false,
        isFavorite = favorite,
        useCount = useCount,
        lastUsedAt = lastUsedAt,
        createdAt = createdAt,
        defaultRank = 20
    )
}

fun defaultCommandShortcuts(now: Long = System.currentTimeMillis()): List<CommandShortcut> {
    fun preset(
        id: String,
        title: String,
        command: String,
        category: CommandCategory,
        defaultRank: Int,
        dangerous: Boolean = false
    ): CommandShortcut {
        return CommandShortcut(
            id = id,
            title = title,
            command = command,
            category = category,
            dangerous = dangerous,
            builtIn = true,
            createdAt = now,
            defaultRank = defaultRank
        )
    }

    return listOf(
        preset("codex_default", "Codex", "codex", CommandCategory.Ai, 130),
        preset("codex_full_auto", "Codex 自动执行", "codex --full-auto", CommandCategory.Ai, 122),
        preset("claude_default", "Claude", "claude", CommandCategory.Ai, 120),
        preset("claude_dont_ask", "Claude 免确认", "claude --permission-mode dontAsk", CommandCategory.Ai, 116),
        preset(
            "codex_danger",
            "Codex 最大权限",
            "codex --dangerously-bypass-approvals-and-sandbox",
            CommandCategory.HighRisk,
            112,
            dangerous = true
        ),
        preset(
            "claude_danger",
            "Claude 最大权限",
            "claude --dangerously-skip-permissions",
            CommandCategory.HighRisk,
            108,
            dangerous = true
        ),
        preset("git_status", "Git 状态", "git status", CommandCategory.Git, 82),
        preset("git_pull", "Git 拉最新", "git pull --rebase", CommandCategory.Git, 78),
        preset("git_diff", "Git 看改动", "git diff", CommandCategory.Git, 76),
        preset("git_log", "Git 最近提交", "git log --oneline -n 10", CommandCategory.Git, 72),
        preset("pnpm_dev", "PNPM 开发", "pnpm dev", CommandCategory.Run, 70),
        preset("npm_dev", "NPM 开发", "npm run dev", CommandCategory.Run, 68),
        preset("cargo_run", "Cargo 运行", "cargo run", CommandCategory.Run, 66),
        preset("docker_up", "Docker Compose 启动", "docker compose up -d", CommandCategory.Run, 62),
        preset("pytest_q", "Pytest", "pytest -q", CommandCategory.Test, 64),
        preset("cargo_test", "Cargo 测试", "cargo test", CommandCategory.Test, 62),
        preset("pnpm_vitest", "PNPM Vitest", "pnpm vitest", CommandCategory.Test, 60),
        preset("npm_test", "NPM Test", "npm test", CommandCategory.Test, 58)
    )
}

fun buildCommandLibraryUiState(
    catalog: List<CommandShortcut>,
    now: Long = System.currentTimeMillis()
): CommandLibraryUiState {
    val normalizedCatalog = catalog
        .filter { it.command.isNotBlank() }
        .distinctBy { it.command }

    val favorites = normalizedCatalog
        .filter { it.isFavorite }
        .sortedWith(commandSectionComparator())

    val recent = normalizedCatalog
        .filter { it.lastUsedAt > 0L }
        .sortedByDescending { it.lastUsedAt }
        .take(8)

    val recommended = normalizedCatalog
        .sortedByDescending { recommendationScore(it, now) }
        .take(6)

    val sections = COMMAND_CATEGORY_ORDER.mapNotNull { category ->
        val commands = normalizedCatalog
            .filter { it.category == category }
            .sortedWith(commandSectionComparator())
        if (commands.isEmpty()) {
            null
        } else {
            CommandShortcutSection(
                key = category.key,
                label = category.label,
                commands = commands
            )
        }
    }

    return CommandLibraryUiState(
        recommended = recommended,
        favorites = favorites,
        recent = recent,
        sections = sections
    )
}

private fun commandSectionComparator(): Comparator<CommandShortcut> {
    return compareByDescending<CommandShortcut> { it.isFavorite }
        .thenByDescending { it.useCount }
        .thenByDescending { it.lastUsedAt }
        .thenByDescending { it.defaultRank }
        .thenBy { it.title.lowercase() }
}

private fun recommendationScore(command: CommandShortcut, now: Long): Double {
    val favoriteBoost = if (command.isFavorite) 260.0 else 0.0
    val customBoost = if (!command.builtIn) 40.0 else 0.0
    val usageBoost = if (command.useCount > 0) ln(command.useCount + 1.0) * 120.0 else 0.0
    val recencyBoost = when {
        command.lastUsedAt <= 0L -> 0.0
        else -> {
            val ageHours = ((now - command.lastUsedAt).coerceAtLeast(0L)) / 3_600_000.0
            (180.0 - ageHours * 8.0).coerceAtLeast(0.0)
        }
    }
    val riskPenalty = if (command.dangerous) 12.0 else 0.0
    return command.defaultRank + favoriteBoost + customBoost + usageBoost + recencyBoost - riskPenalty
}
