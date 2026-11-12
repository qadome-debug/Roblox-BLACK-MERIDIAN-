--!strict
-- Fixed-step accumulator (BM-007).
--
-- Converts variable frame time into a whole number of fixed simulation
-- steps so the authoritative simulation (BM-054) advances in identical
-- increments regardless of frame rate. Given the same inputs at the same
-- step numbers, two runs produce the same result.

export type FixedStep = {
	stepSeconds: number,
	-- Adds elapsed time and returns how many whole steps to simulate now.
	-- Never more than `maxStepsPerAdvance`; time beyond that is dropped so a
	-- stalled server catches up instead of spiralling.
	accumulate: (self: FixedStep, elapsed: number) -> number,
	-- Fraction of a step accumulated but not yet simulated, in [0, 1). For
	-- presentation interpolation only.
	alpha: (self: FixedStep) -> number,
	-- Total steps handed out so far.
	stepCount: (self: FixedStep) -> number,
	reset: (self: FixedStep) -> (),
}

local FixedStep = {}

function FixedStep.new(stepSeconds: number, maxStepsPerAdvance: number?): FixedStep
	if type(stepSeconds) ~= "number" or stepSeconds <= 0 or stepSeconds ~= stepSeconds then
		error("FixedStep.new: stepSeconds must be a positive number", 2)
	end
	local maxSteps = maxStepsPerAdvance or 8
	if maxSteps < 1 or maxSteps % 1 ~= 0 then
		error("FixedStep.new: maxStepsPerAdvance must be a positive integer", 2)
	end

	local accumulator = 0
	local count = 0

	local fixed = {} :: FixedStep
	fixed.stepSeconds = stepSeconds

	function fixed:accumulate(elapsed: number): number
		if type(elapsed) ~= "number" or elapsed ~= elapsed or elapsed < 0 then
			error("FixedStep:accumulate expects a nonnegative number", 2)
		end
		accumulator += elapsed
		local steps = math.floor(accumulator / stepSeconds)
		if steps > maxSteps then
			steps = maxSteps
			accumulator = 0
		else
			accumulator -= steps * stepSeconds
		end
		count += steps
		return steps
	end

	function fixed:alpha(): number
		return accumulator / stepSeconds
	end

	function fixed:stepCount(): number
		return count
	end

	function fixed:reset()
		accumulator = 0
		count = 0
	end

	return table.freeze(fixed)
end

return table.freeze(FixedStep)
