// A model's effort levels are read off whatever the registry reports, which
// is provider data this plugin does not control. A client renders a picker
// from the answer, so the distinction between "no effort control" and "not
// reported yet" has to survive the trip: this is the empty-list side of it,
// and the only shape either the model list or the state snapshot puts on the
// wire.

import { describe, expect, test } from "bun:test";
import type { Model } from "@oh-my-pi/pi-ai";

import { offeredLevels } from "../src/normalize.js";

function model(thinking?: { efforts?: string[] }): Model {
	return { id: "m", provider: "p", name: "M", thinking } as unknown as Model;
}

describe("offeredLevels", () => {
	test("a model with efforts offers them after the two universal ones", () => {
		expect(offeredLevels(model({ efforts: ["low", "high"] }))).toEqual([
			"inherit",
			"off",
			"low",
			"high",
		]);
	});

	test("a model with no effort surface offers an empty list, never undefined", () => {
		for (const m of [model(), model({}), model({ efforts: [] })]) {
			const levels = offeredLevels(m);
			expect(levels).toEqual([]);
			// The point of the shape: a client can tell this apart from a
			// field that is not there yet, and only if it is really a list.
			expect(Array.isArray(levels)).toBe(true);
		}
	});

	test("a no-effort model still cannot be sent inherit or off", () => {
		// Both exist for every model that has an effort surface at all, so
		// offering them for one that has none would name a setting the
		// workstation would reject.
		expect(offeredLevels(model({ efforts: [] }))).not.toContain("inherit");
	});
});
