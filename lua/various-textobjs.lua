local getCursor = vim.api.nvim_win_get_cursor
local setCursor = vim.api.nvim_win_set_cursor
local bo = vim.bo
local fn = vim.fn
local opt = vim.opt

local M = {}
--------------------------------------------------------------------------------
-- CONFIG
-- default value
local lookForwL = 5

local function setupKeymaps()
	local innerOuterMaps = {
		number = "n",
		value = "v",
		subWord = "S",
	}
	local oneMaps = {
		nearEoL = "n",
		restOfParagraph = "r",
		diagnostic = "!",
		column = "|",
	}
	local ftMaps = {
		{
			map = { jsRegex = "/" },
			fts = { "javascript", "typescript" },
		},
		{
			map = { mdlink = "l" },
			fts = { "markdown" },
		},
		{
			map = { mdFencedCodeBlock = "C" },
			fts = { "markdown" },
		},
		{
			map = { doubleSquareBrackets = "D" },
			fts = { "lua", "norg", "sh", "fish", "zsh", "bash", "markdown" },
		},
		{
			map = { cssSelector = "c" },
			fts = { "css", "scss" },
		},
	}
	-----------------------------------------------------------------------------
	local keymap = vim.keymap.set
	for objName, map in pairs(innerOuterMaps) do
		local name = " " .. objName .. " textobj"
		keymap({ "o", "x" }, "a" .. map, function() M[objName](false) end, { desc = "outer" .. name })
		keymap({ "o", "x" }, "i" .. map, function() M[objName](true) end, { desc = "inner" .. name })
	end
	for objName, map in pairs(oneMaps) do
		keymap({ "o", "x" }, map, M[objName], { desc = objName .. " textobj" })
	end
	-- stylua: ignore start
	keymap( { "o", "x" }, "ii" , function() M.indentation(true, true) end, { desc = "inner-inner indentation textobj" })
	keymap( { "o", "x" }, "ai" , function() M.indentation(false, true) end, { desc = "outer-inner indentation textobj" })
	keymap( { "o", "x" }, "iI" , function() M.indentation(true, true) end, { desc = "inner-inner indentation textobj" })
	keymap( { "o", "x" }, "aI" , function() M.indentation(false, false) end, { desc = "outer-outer indentation textobj" })

	vim.api.nvim_create_augroup("VariousTextobjs", {})
	for _, textobj in pairs(ftMaps) do
		vim.api.nvim_create_autocmd("FileType", {
			group = "VariousTextobjs",
			pattern = textobj.fts,
			callback = function()
				for objName, map in pairs(textobj.map) do
					local name = " " .. objName .. " textobj"
					keymap( { "o", "x" }, "a" .. map, function() M[objName](false) end, { desc = "outer" .. name, buffer = true })
					keymap( { "o", "x" }, "i" .. map, function() M[objName](true) end, { desc = "inner" .. name, buffer = true })
				end
			end,
		})
	end
	-- stylua: ignore end
end

---optional setup function
---@param opts table
function M.setup(opts)
	if opts.lookForwardLines then lookForwL = opts.lookForwardLines end
	if opts.useDefaultKeymaps then setupKeymaps() end
end

--------------------------------------------------------------------------------

---runs :normal natively with bang
---@param cmdStr any
local function normal(cmdStr) vim.cmd.normal { cmdStr, bang = true } end

---@return boolean
local function isVisualMode()
	local modeWithV = fn.mode():find("v")
	return modeWithV ~= nil
end

---@return boolean
local function isVisualLineMode()
	local modeWithV = fn.mode():find("V")
	return modeWithV ~= nil
end

---notification when no textobj could be found
local function notFoundMsg()
	local msg = "Textobject not found within " .. tostring(lookForwL) .. " lines."
	if lookForwL == 1 then msg = msg:gsub("s%.$", ".") end -- remove plural s
	vim.notify(msg, vim.log.levels.WARN)
end

---sets the selection for the textobj (characterwise)
---@class pos number[]
---@param startpos pos
---@param endpos pos
local function setSelection(startpos, endpos)
	setCursor(0, startpos)
	if isVisualMode() then
		normal("o")
	else
		normal("v")
	end
	setCursor(0, endpos)
end

---sets the selection for the textobj (linewise)
---@param startline integer
---@param endline integer
local function setLinewiseSelection(startline, endline)
	setCursor(0, { startline, 0 })
	if not isVisualLineMode() then normal("V") end
	normal("o")
	setCursor(0, { endline, 0 })
end

---Seek and select characterwise text object based on pattern.
---@param pattern string lua pattern. Requires two capture groups marking the two additions for the outer variant of the textobj. Use an empty capture group when there is no difference between inner and outer on that side.
---@param inner boolean true = inner textobj
---@return boolean whether textobj search was successful
local function searchTextobj(pattern, inner)
	local cursorRow, cursorCol = unpack(getCursor(0))
	---@diagnostic disable-next-line: assign-type-mismatch
	local lineContent = fn.getline(cursorRow) ---@type string
	local lastLine = fn.line("$")
	local beginCol = 0
	local endCol, captureG1, captureG2

	-- first line: check if standing on or in front of textobj
	repeat
		beginCol, endCol, captureG1, captureG2 = lineContent:find(pattern, beginCol + 1)
		standingOnOrInFront = endCol and endCol >= cursorCol
	until not beginCol or standingOnOrInFront

	-- subsequent lines: search full line for first occurrence
	local i = 0
	while not standingOnOrInFront do
		i = i + 1
		if i > lookForwL or cursorRow + i > lastLine then
			notFoundMsg()
			return false
		end
		---@diagnostic disable-next-line: assign-type-mismatch
		lineContent = fn.getline(cursorRow + i) ---@type string

		beginCol, endCol, captureG1, captureG2 = lineContent:find(pattern)
		if beginCol then break end
	end

	-- capture groups determine the inner/outer difference
	-- INFO :find() returns integers of the position if the capture group is empty
	if inner then
		local frontOuterLen = type(captureG1) ~= "number" and #captureG1 or 0
		local backOuterLen = type(captureG2) ~= "number" and #captureG2 or 0
		beginCol = beginCol + frontOuterLen
		endCol = endCol - backOuterLen
	end

	setSelection({ cursorRow + i, beginCol - 1 }, { cursorRow + i, endCol - 1 })
	return true
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

---Subword (word with "-_." as delimiters)
---@param inner boolean
function M.subword(inner)
	local iskeywBefore = opt.iskeyword:get()
	opt.iskeyword:remove { "_", "-", "." }
	if not isVisualMode() then normal("v") end

	if inner then
		normal("iw")
	else
		normal("aw")
	end

	opt.iskeyword = iskeywBefore
end

---near end of the line, ignoring trailing whitespace (relevant for markdown)
function M.nearEoL()
	if not isVisualMode() then normal("v") end
	normal("$")

	-- loop ensures trailing whitespace is not counted, relevant e.g., for markdown
	---@diagnostic disable-next-line: assign-type-mismatch, param-type-mismatch
	local lineContent = fn.getline(".") ---@type string
	local col = fn.col("$")
	repeat
		normal("h")
		col = col - 1
		local lastChar = lineContent:sub(col, col)
	until not lastChar:find("%s") or col == 1

	normal("h")
end

---rest of paragraph (linewise)
function M.restOfParagraph()
	if not isVisualLineMode() then normal("V") end
	normal("}")
end

---DIAGNOSTIC TEXT OBJECT
---similar to https://github.com/andrewferrier/textobj-diagnostic.nvim
---requires builtin LSP
function M.diagnostic()
	local d = vim.diagnostic.get_next { wrap = false }
	if not d then return end
	local curLine = fn.line(".")
	if curLine + lookForwL > d.lnum then return end
	setSelection({ d.lnum + 1, d.col }, { d.end_lnum + 1, d.end_col })
end

-- INDENTATION OBJECT
---indentation textobj, based on https://thevaluable.dev/vim-create-text-objects/
---@param noStartBorder boolean exclude the startline
---@param noEndBorder boolean exclude the endline
function M.indentation(noStartBorder, noEndBorder)
	local function isBlankLine(lineNr)
		---@diagnostic disable-next-line: assign-type-mismatch
		local lineContent = fn.getline(lineNr) ---@type string
		return string.find(lineContent, "^%s*$") == 1
	end

	local indentofStart = fn.indent(fn.line("."))
	if indentofStart == 0 then return end -- do not select whole file or blank line

	local prevLnum = fn.line(".") - 1 -- line before cursor
	while prevLnum > 0 and (isBlankLine(prevLnum) or fn.indent(prevLnum) >= indentofStart) do
		prevLnum = prevLnum - 1
	end
	local nextLnum = fn.line(".") + 1 -- line after cursor
	local lastLine = fn.line("$")
	while nextLnum <= lastLine and (isBlankLine(nextLnum) or fn.indent(nextLnum) >= indentofStart) do
		nextLnum = nextLnum + 1
	end

	-- differentiate ai and ii
	if noStartBorder then prevLnum = prevLnum + 1 end
	if noEndBorder then nextLnum = nextLnum - 1 end

	setLinewiseSelection(prevLnum, nextLnum)
end

---Column Textobj (blockwise down until indent or shorter line)
function M.column()
	local lastLnum = fn.line("$")
	local nextLnum, cursorCol = unpack(getCursor(0))
	local extraColumns = vim.v.count1 - 1 -- has to be done before running the other :normal commands, since they change v:count

	-- get accurate cursorCol (account for tabs/spaces properly)
	if not bo.expandtab then
		local indentLevel = (fn.indent(".") / bo.tabstop) ---@diagnostic disable-line: param-type-mismatch
		cursorCol = cursorCol + (indentLevel * (bo.tabstop - 1))
	end

	repeat
		nextLnum = nextLnum + 1
		local trueLineLength = #fn.getline(nextLnum):gsub("\t", string.rep(" ", bo.tabstop)) ---@diagnostic disable-line: undefined-field
		local shorterLine = trueLineLength < cursorCol
		local hitsIndent = cursorCol < fn.indent(nextLnum)
		local eof = nextLnum > lastLnum
	until eof or hitsIndent or shorterLine
	nextLnum = nextLnum - 1

	-- start visual block mode
	if not (fn.mode() == "CTRL-V") then vim.cmd.execute([["normal! \<C-v>"]]) end

	normal(nextLnum .. "G")
	if extraColumns > 0 then normal(tostring(extraColumns) .. "l") end
end

---Md Fenced Code Block Textobj
---@param inner boolean inner excludes the backticks
function M.mdFencedCodeBlock(inner)
	local lastLnum = fn.line("$")
	local cursorLnum = fn.line(".")
	local codeBlockPattern = "^```%w*$"

	-- scan buffer for all code blocks, add beginnings & endings to a table each
	local cbBegin = {}
	local cbEnd = {}
	for i = 1, lastLnum, 1 do
		---@diagnostic disable: assign-type-mismatch
		local lineContent = fn.getline(i) ---@type string
		if lineContent:find(codeBlockPattern) then
			if #cbBegin == #cbEnd then
				table.insert(cbBegin, i)
			else
				table.insert(cbEnd, i)
			end
		end
	end
	if #cbBegin > #cbEnd then table.remove(cbEnd) end -- incomplete codeblock

	-- determine cursor location in a codeblock
	local j = 0
	repeat
		j = j + 1
		if j > #cbBegin then
			notFoundMsg()
			return
		end
		local cursorInBetween = (cbBegin[j] <= cursorLnum) and (cbEnd[j] >= cursorLnum)
		-- seek forward for a codeblock
		local cursorInFront = (cbBegin[j] > cursorLnum) and (cbBegin[j] <= cursorLnum + lookForwL)
	until cursorInBetween or cursorInFront

	local start = cbBegin[j]
	local ending = cbEnd[j]
	if inner then
		start = start + 1
		ending = ending - 1
	end

	setLinewiseSelection(start, ending)
end

---value text object
---@param inner boolean inner value excludes trailing commas or semicolons, outer includes them. Both exclude trailing comments.
---@diagnostic disable: param-type-mismatch
function M.value(inner)
	-- captures value till the end of the line
	-- negative sets to not find equality comparators == or css pseudo-elements ::
	local pattern = "([^=:][=:] ?)[^=:].*()"

	local valueFound = searchTextobj(pattern, true)
	if not valueFound then return end

	-- if value found, remove trailing comment from it
	local commentPat = bo.commentstring:gsub(" ?%%s.*", "") -- remove placeholder and backside of commentstring
	commentPat = vim.pesc(commentPat) -- escape lua pattern
	commentPat = " *" .. commentPat .. ".*" -- to match till end of line

	---@diagnostic disable-next-line: undefined-field
	local lineContent = fn.getline("."):gsub(commentPat, "") -- remove commentstring
	local valueEndCol = #lineContent - 1

	-- inner value = without trailing comma/semicolon
	if inner and lineContent:find("[,;]$") then valueEndCol = valueEndCol - 1 end

	local curRow = fn.line(".")
	setCursor(0, { curRow, valueEndCol })
end
---@diagnostic enable: param-type-mismatch

---number textobj
---@param inner boolean inner number consists purely of digits, outer number factors in decimal points and includes minus sign
function M.number(inner)
	-- here two different patterns make more sense, so the inner number can match
	-- before and after the decimal dot. enforcing digital after dot so outer
	-- excludes enumrations.
	local pattern = inner and "%d+" or "%-?%d*%.?%d+"
	searchTextobj(pattern, false)
end

--------------------------------------------------------------------------------
-- FILETYPE SPECIFIC TEXTOBJS

---md links textobj
---@param inner boolean inner link only includes the link title, outer link includes link, url, and the four brackets.
function M.mdlink(inner)
	local pattern = "(%[).-(%]%b())"
	searchTextobj(pattern, inner)
end

---double square brackets
---@param inner boolean inner double square brackets exclude the brackets themselves
function M.doubleSquareBrackets(inner)
	local pattern = "(%[%[).-(%]%])"
	searchTextobj(pattern, inner)
end

---JS Regex
---@param inner boolean inner regex excludes the slashes (and flags)
function M.jsRegex(inner)
	-- [^\] to not match escaped slash in regex, %l* to match flags
	local pattern = [[(/).-[^\](/%l*)]]
	searchTextobj(pattern, inner)
end

---CSS Selector Textobj
---@param inner boolean inner selector or outer selector which includes trailing comma and whitespace
function M.cssSelector(inner)
	local pattern = "()%.[%w-_]+(,? ?)"
	searchTextobj(pattern, inner)
end

--------------------------------------------------------------------------------
return M
