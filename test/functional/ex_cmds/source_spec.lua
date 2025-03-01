local t = require('test.testutil')
local n = require('test.functional.testnvim')()

local command = n.command
local insert = n.insert
local eq = t.eq
local clear = n.clear
local api = n.api
local fn = n.fn
local feed = n.feed
local feed_command = n.feed_command
local write_file = t.write_file
local tmpname = t.tmpname
local exec = n.exec
local exc_exec = n.exc_exec
local exec_lua = n.exec_lua
local eval = n.eval
local exec_capture = n.exec_capture
local neq = t.neq
local matches = t.matches
local mkdir = t.mkdir
local rmdir = n.rmdir
local is_os = t.is_os

describe(':source', function()
  before_each(function()
    clear()
  end)

  it('sourcing a file that is deleted and recreated is consistent vim-patch:8.1.0151', function()
    local test_file = 'Xfile.vim'
    local other_file = 'Xfoobar'
    local script = [[
      func Func()
      endfunc
    ]]
    write_file(test_file, script)
    command('source ' .. test_file)
    os.remove(test_file)
    write_file(test_file, script)
    command('source ' .. test_file)
    os.remove(test_file)
    write_file(other_file, '')
    write_file(test_file, script)
    command('source ' .. test_file)
    os.remove(other_file)
    os.remove(test_file)
  end)

  it("changing 'shellslash' changes the result of expand()", function()
    if not is_os('win') then
      pending("'shellslash' only works on Windows")
      return
    end
    api.nvim_set_option_value('shellslash', false, {})
    mkdir('Xshellslash')

    write_file(
      [[Xshellslash/Xstack.vim]],
      [[
      let g:stack1 = expand('<stack>')
      set shellslash
      let g:stack2 = expand('<stack>')
      set noshellslash
      let g:stack3 = expand('<stack>')
    ]]
    )

    for _ = 1, 2 do
      command([[source Xshellslash/Xstack.vim]])
      matches([[Xshellslash\Xstack%.vim]], api.nvim_get_var('stack1'))
      matches([[Xshellslash/Xstack%.vim]], api.nvim_get_var('stack2'))
      matches([[Xshellslash\Xstack%.vim]], api.nvim_get_var('stack3'))
    end

    write_file(
      [[Xshellslash/Xstack.lua]],
      [[
      vim.g.stack1 = vim.fn.expand('<stack>')
      vim.o.shellslash = true
      vim.g.stack2 = vim.fn.expand('<stack>')
      vim.o.shellslash = false
      vim.g.stack3 = vim.fn.expand('<stack>')
    ]]
    )

    for _ = 1, 2 do
      command([[source Xshellslash/Xstack.lua]])
      matches([[Xshellslash\Xstack%.lua]], api.nvim_get_var('stack1'))
      matches([[Xshellslash/Xstack%.lua]], api.nvim_get_var('stack2'))
      matches([[Xshellslash\Xstack%.lua]], api.nvim_get_var('stack3'))
    end

    rmdir('Xshellslash')
  end)

  it('current buffer', function()
    insert([[
      let a = 2
      let b = #{
        \ k: "v"
       "\ (o_o)
        \ }
      let c = expand("<SID>")
      let s:s = 0zbeef.cafe
      let d = s:s]])

    command('source')
    eq('2', exec_capture('echo a'))
    eq("{'k': 'v'}", exec_capture('echo b'))
    eq('<SNR>1_', exec_capture('echo c'))
    eq('0zBEEFCAFE', exec_capture('echo d'))

    exec('set cpoptions+=C')
    eq("Vim(let):E723: Missing end of Dictionary '}': ", exc_exec('source'))
  end)

  it('selection in current buffer', function()
    insert([[
      let a = 2
      let a = 3
      let a = 4
      let b = #{
       "\ (>_<)
        \ K: "V"
        \ }
      function! s:C() abort
        return expand("<SID>") .. "C()"
      endfunction
      let D = {-> s:C()}]])

    -- Source the 2nd line only
    feed('ggjV')
    feed_command(':source')
    eq('3', exec_capture('echo a'))

    -- Source last line only
    feed_command(':$source')
    eq('Vim(echo):E117: Unknown function: s:C', exc_exec('echo D()'))

    -- Source from 2nd line to end of file
    feed('ggjVG')
    feed_command(':source')
    eq('4', exec_capture('echo a'))
    eq("{'K': 'V'}", exec_capture('echo b'))
    eq('<SNR>1_C()', exec_capture('echo D()'))

    -- Source last line after the lines that define s:C() have been sourced
    feed_command(':$source')
    eq('<SNR>1_C()', exec_capture('echo D()'))

    exec('set cpoptions+=C')
    eq("Vim(let):E723: Missing end of Dictionary '}': ", exc_exec("'<,'>source"))
  end)

  it('does not break if current buffer is modified while sourced', function()
    insert [[
      bwipeout!
      let a = 123
    ]]
    command('source')
    eq('123', exec_capture('echo a'))
  end)

  it('multiline heredoc command', function()
    insert([[
      lua << EOF
      y = 4
      EOF]])

    command('source')
    eq('4', exec_capture('echo luaeval("y")'))
  end)

  --- @param verbose boolean
  local function test_source_lua_file(verbose)
    local test_file = 'Xtest.lua'
    write_file(
      test_file,
      [[
      vim.g.sourced_lua = 1
      vim.g.sfile_value = vim.fn.expand('<sfile>')
      vim.g.stack_value = vim.fn.expand('<stack>')
      vim.g.script_value = vim.fn.expand('<script>')
      vim.g.script_id = tonumber(vim.fn.expand('<SID>'):match('<SNR>(%d+)_'))
      vim.o.mouse = 'nv'
    ]]
    )

    command('set shellslash')
    command(('%ssource %s'):format(verbose and 'verbose ' or '', test_file))
    eq(1, eval('g:sourced_lua'))
    matches([[/Xtest%.lua$]], api.nvim_get_var('sfile_value'))
    matches([[/Xtest%.lua$]], api.nvim_get_var('stack_value'))
    matches([[/Xtest%.lua$]], api.nvim_get_var('script_value'))

    local expected_sid = fn.getscriptinfo({ name = test_file })[1].sid
    local sid = api.nvim_get_var('script_id')
    eq(expected_sid, sid)
    eq(sid, api.nvim_get_option_info2('mouse', {}).last_set_sid)

    os.remove(test_file)
  end

  it('can source lua files', function()
    test_source_lua_file(false)
  end)

  it('with :verbose modifier can source lua files', function()
    test_source_lua_file(true)
  end)

  describe('can source current buffer', function()
    local function test_source_lua_curbuf()
      it('selected region', function()
        insert([[
          vim.g.b = 5
          vim.g.b = 6
          vim.g.b = 7
          a = [=[
           "\ a
            \ b]=]
        ]])
        feed('dd')

        feed('ggjV')
        feed_command(':source')
        eq(6, eval('g:b'))

        feed('GVkk')
        feed_command(':source')
        eq(' "\\ a\n  \\ b', exec_lua('return _G.a'))
      end)

      it('whole buffer', function()
        insert([[
          vim.g.c = 10
          vim.g.c = 11
          vim.g.c = 12
          a = [=[
            \ 1
           "\ 2]=]
          vim.g.sfile_value = vim.fn.expand('<sfile>')
          vim.g.stack_value = vim.fn.expand('<stack>')
          vim.g.script_value = vim.fn.expand('<script>')
        ]])
        feed('dd')

        feed_command(':source')

        eq(12, eval('g:c'))
        eq('  \\ 1\n "\\ 2', exec_lua('return _G.a'))
        eq(':source buffer=1', api.nvim_get_var('sfile_value'))
        eq(':source buffer=1', api.nvim_get_var('stack_value'))
        eq(':source buffer=1', api.nvim_get_var('script_value'))
      end)
    end

    describe('with ft=lua', function()
      before_each(function()
        command('setlocal ft=lua')
      end)
      test_source_lua_curbuf()
    end)

    describe('with .lua extension', function()
      before_each(function()
        command('edit ' .. tmpname() .. '.lua')
      end)
      test_source_lua_curbuf()
    end)
  end)

  it("doesn't throw E484 for lua parsing/runtime errors", function()
    local test_file = 'Xtest.lua'

    -- Does throw E484 for unreadable files
    local ok, result = pcall(exec_capture, ':source ' .. test_file .. 'noexisting')
    eq(false, ok)
    neq(nil, result:find('E484'))

    -- Doesn't throw for parsing error
    write_file(test_file, 'vim.g.c = ')
    ok, result = pcall(exec_capture, ':source ' .. test_file)
    eq(false, ok)
    eq(nil, result:find('E484'))
    os.remove(test_file)

    -- Doesn't throw for runtime error
    write_file(test_file, "error('Cause error anyway :D')")
    ok, result = pcall(exec_capture, ':source ' .. test_file)
    eq(false, ok)
    eq(nil, result:find('E484'))
    os.remove(test_file)
  end)
end)

it('$HOME is not shortened in filepath in v:stacktrace from sourced file', function()
  local sep = n.get_pathsep()
  local xhome = table.concat({ vim.uv.cwd(), 'Xhome' }, sep)
  mkdir(xhome)
  clear({ env = { HOME = xhome } })
  finally(function()
    rmdir(xhome)
  end)
  local filepath = table.concat({ xhome, 'Xstacktrace.vim' }, sep)
  local script = [[
    func Xfunc()
      throw 'Exception from Xfunc'
    endfunc
  ]]
  write_file(filepath, script)
  exec('source ' .. filepath)
  exec([[
    try
      call Xfunc()
    catch
      let g:stacktrace = v:stacktrace
    endtry
  ]])
  eq(filepath, n.eval('g:stacktrace[-1].filepath'))
end)
