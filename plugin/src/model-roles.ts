// Role model assignments (docs/protocol.md, "Model settings").
//
// A role is a named slot core resolves through `@<role>`: `smol` for cheap
// side work, `task` for subagents, `advisor` for the watchdog. The
// assignments live in config.yml, not on the session, so this module reaches
// the live `Settings` singleton the host initialized at startup rather than
// loading a second copy that would then disagree with it.

import { Settings } from "@oh-my-pi/pi-coding-agent";
import type { ExtensionContext } from "@oh-my-pi/pi-coding-agent";
import type { ModelRoleInfo } from "./protocol-types.js";

// Core's own role list is not exported from the package root, and the deep
// path is not published, so the built-ins are named here. Configured roles
// are unioned in below, so a custom role still appears; a new built-in would
// need this list updated.
const BUILTIN_ROLES: readonly string[] = [
	"default",
	"smol",
	"slow",
	"vision",
	"plan",
	"commit",
	"tiny",
	"task",
	"advisor",
];

const ROLE_PURPOSE: Record<string, string> = {
	default: "Every turn that does not name another role",
	smol: "Cheap, fast side work",
	slow: "The most capable model, for hard problems",
	vision: "Images",
	plan: "Planning passes",
	commit: "Commit messages",
	tiny: "The smallest jobs: titles and classification",
	task: "Subagents spawned by task",
	advisor: "The watchdog that reviews the session",
};

/// The live settings the running session reads. Undefined only if the host
/// never initialized the singleton, which would mean omp is not running.
function liveSettings(): Settings | undefined {
	try {
		return Settings.instance;
	} catch {
		return undefined;
	}
}

/// Every role a client can set, each with what it is for, what it currently
/// resolves to, and where that assignment came from. An unassigned role
/// falls through to `default`, so `resolved` is filled in either way and
/// `configured` says whether the slot itself holds anything.
export function listModelRoles(ctx: ExtensionContext): ModelRoleInfo[] {
	const settings = liveSettings();
	const assigned = settings?.getModelRoles() ?? {};
	const ids = [...BUILTIN_ROLES];
	for (const role of Object.keys(assigned)) {
		if (!ids.includes(role)) ids.push(role);
	}

	return ids.map((role) => {
		const configured = assigned[role];
		const model = ctx.models.resolve(`@${role}`);
		const info: ModelRoleInfo = {
			role,
			purpose: ROLE_PURPOSE[role],
		};
		if (configured !== undefined) info.configured = configured;
		if (model) {
			info.resolvedProvider = model.provider;
			info.resolvedId = model.id;
		}
		if (settings) info.source = settings.getModelRoleProvenance(role);
		return info;
	});
}

/// Assigns a model to a role, or clears the assignment when `modelId` is
/// undefined. The model is resolved first: a role pointing at a model this
/// machine cannot authenticate would break every turn that used it, and the
/// failure would surface far from here.
export function setModelRole(
	ctx: ExtensionContext,
	role: string,
	modelId: string | undefined,
): { error: string } | { role: string; configured?: string } {
	const settings = liveSettings();
	if (!settings) return { error: "settings are not available in this session" };

	const trimmed = role.trim();
	if (trimmed.length === 0) return { error: "role must not be empty" };

	if (modelId === undefined) {
		settings.setModelRole(trimmed, undefined);
		return { role: trimmed };
	}

	const model = ctx.models.resolve(modelId);
	if (!model) return { error: `no authenticated model matches ${modelId}` };

	// Store what core stores: a `provider/id` selector, not the display name,
	// so the assignment survives a catalog that renames a label.
	const base = `${model.provider}/${model.id}`;

	// A configured role may carry an effort suffix (`:xhigh`). Re-picking the
	// same model must not silently drop it: only a genuine model change
	// discards the suffix, because the suffix belonged to the old model.
	const explicit = modelId.includes(":") ? modelId.slice(modelId.indexOf(":")) : "";
	const previous = settings.getModelRole(trimmed);
	const inherited =
		explicit === "" && previous !== undefined && previous.split(":")[0] === base
			? previous.slice(base.length)
			: "";

	const selector = `${base}${explicit || inherited}`;
	settings.setModelRole(trimmed, selector);
	return { role: trimmed, configured: selector };
}
