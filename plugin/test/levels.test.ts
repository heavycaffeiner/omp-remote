// A model's effort levels are read off whatever the registry reports, which
// is provider data this plugin does not control. A client renders a picker
// from the answer, so the distinction between "no effort control" and "not
// reported yet" has to survive the trip: empty list versus absent.

import { describe, expect, test } from "bun:test";
import type { Model } from "@oh-my-pi/pi-ai";

import { thinkingLevelsFor } from "../src/normalize.js";

function model(thinking?: { efforts?: string[] }): Model {
	return { id: "m", provider: "p", name: "M", thinking } as unknown as Model;
}

describe("thinkingLevelsFor", () => {
	test("a model with efforts offers them after the two universal ones", () => {
		expect(thinkingLevelsFor(model({ efforts: ["low", "high"] }))).toEqual([
			"inherit",
			"off",
			"low",
			"high",
		]);
	});

	test("a model with no effort surface offers nothing", () => {
		expect(thinkingLevelsFor(model())).toBeUndefined();
		expect(thinkingLevelsFor(model({}))).toBeUndefined();
		expect(thinkingLevelsFor(model({ efforts: [] }))).toBeUndefined();
	});

	test("no model at all is not an answer about any model", () => {
		expect(thinkingLevelsFor(undefined)).toBeUndefined();
	});
});
