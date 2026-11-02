local t = require('test.testutil')
local n = require('test.functional.testnvim')()
local Screen = require('test.functional.ui.screen')

local clear, eq, ok = n.clear, t.eq, t.ok
local api, command, exec, feed = n.api, n.command, n.exec, n.feed

--- Text shown by the UI at 0-based screen position.
local function cell(screen, row, col)
  local r = screen._grids[1].rows[row + 1]
  return r and r[col + 1] and r[col + 1].text
end

--- All character start positions of the buffer in window "win", as [row0, col0].
local function all_positions(win)
  local buf = api.nvim_win_get_buf(win)
  local pos, chars = {}, {}
  for l, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, true)) do
    local col = 0
    for ch in line:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
      table.insert(pos, { l - 1, col })
      table.insert(chars, ch)
      col = col + #ch
    end
  end
  return pos, chars
end

--- The oracle property: every position the API reports as drawn text shows its
--- character at "abs" in the UI grid, and its cells add up to its width.
--- Returns the results keyed by "row:col" plus the number of checked positions.
local function check_oracle(screen, win, chars_ok)
  win = win or api.nvim_get_current_win()
  local pos, chars = all_positions(win)
  local res = api.nvim__win_screen_cells(win, pos, {})
  eq(#pos, #res)
  local by, checked = {}, 0
  for i, r in ipairs(res) do
    local ch = chars[i]
    local key = pos[i][1] .. ':' .. pos[i][2]
    by[key] = r
    eq(true, r.valid, key)
    if r.kind == 'text' then
      ok(r.visible, 'visible', key)
      local width = 0
      for _, s in ipairs(r.segs) do
        width = width + s[3] - s[2] + 1
      end
      eq(r.vcol1 - r.vcol0 + 1, width, key .. ' width')
      if ch ~= '\t' and not r.skipcol_overlay and (not chars_ok or chars_ok(ch)) then
        eq(ch, cell(screen, r.abs[1], r.abs[2]), key .. ' shows ' .. ch)
      end
      checked = checked + 1
    end
  end
  return by, checked
end

--- Map of results for the given positions.
local function cells(positions, win)
  return api.nvim__win_screen_cells(win or 0, positions, {})
end

local function at(screen, r)
  return cell(screen, r.abs[1], r.abs[2])
end

--- Assert the snapshot (or print it while writing a test).
local function show(screen, snap)
  if snap then
    screen:expect(snap)
  else
    screen:sleep(100)
    screen:print_snapshot()
  end
end

local long = 'the quick brown fox jumps over the lazy dog and keeps running far away'

describe('API nvim__win_screen_cells', function()
  local screen

  before_each(function()
    clear()
    screen = Screen.new(30, 10)
  end)

  describe('oracle property', function()
    local text = {
      'the quick brown fox jumps over the lazy dog and keeps running far away',
      'short',
      'another long line that has to wrap at least once in thirty cols',
    }

    it('wrap', function()
      api.nvim_buf_set_lines(0, 0, -1, true, text)
      screen:expect([[
        ^the quick brown fox jumps over|
         the lazy dog and keeps runnin|
        g far away                    |
        short                         |
        another long line that has to |
        wrap at least once in thirty c|
        ols                           |
        {1:~                             }|*2
                                      |
      ]])
      local _, checked = check_oracle(screen)
      eq(#text[1] + #text[2] + #text[3], checked)
    end)

    it('linebreak', function()
      command('set linebreak')
      api.nvim_buf_set_lines(0, 0, -1, true, text)
      screen:expect([[
        ^the quick brown fox jumps     |
        over the lazy dog and keeps   |
        running far away              |
        short                         |
        another long line that has to |
        wrap at least once in thirty  |
        cols                          |
        {1:~                             }|*2
                                      |
      ]])
      local _, checked = check_oracle(screen)
      eq(#text[1] + #text[2] + #text[3], checked)
    end)

    it('syntax conceal, wrapped rows (boguscols)', function()
      api.nvim_buf_set_lines(0, 0, -1, true, {
        'aaaa XXXXXXXX bbbb cccc dddd eeee XXXX ffff gggg hhhh',
        'no conceal here',
        'XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX tail',
      })
      command('syntax match Hid /XX\\+/ conceal cchar=*')
      command('set conceallevel=2 concealcursor=nvic')
      command('normal! G')
      screen:expect([[
        aaaa {14:*} bbbb cccc dddd e       |
        eee {14:*} ffff gggg hhhh          |
        no conceal here               |
        {14:^*}                             |
         tail                         |
        {1:~                             }|*4
                                      |
      ]])
      local by, checked = check_oracle(screen, nil, function(ch)
        return ch ~= 'X'
      end)
      -- every non-X character is drawn text
      eq(#('aaaa  bbbb cccc dddd eeee  ffff gggg hhhh') + #'no conceal here' + #' tail', checked)
      -- the first X of a run shows the cchar, the rest of the run is concealed
      for _, key in ipairs({ '0:5', '0:34', '2:0' }) do
        eq('concealed', by[key].kind, key)
        eq('*', at(screen, by[key]), key)
      end
      for _, key in ipairs({ '0:6', '0:12', '2:20', '2:35' }) do
        eq('concealed', by[key].kind, key)
        eq(true, by[key].visible, key)
      end
    end)
  end)

  describe('scene', function()
    it('nowrap + leftcol', function()
      command('set nowrap')
      api.nvim_buf_set_lines(0, 0, -1, true, { long, 'short' })
      command('normal! 0020zl')
      show(screen, [[
        ^jumps over the lazy dog and ke|
                                      |
        {1:~                             }|*7
                                      |
      ]])
      local by = check_oracle(screen)
      eq('offscreen', by['0:19'].kind)
      eq(false, by['0:19'].visible)
      eq({ { 0, 0, 0 } }, by['0:20'].segs)
      eq({ { 0, 29, 29 } }, by['0:49'].segs)
      eq('offscreen', by['0:50'].kind)
      eq('offscreen', by['1:0'].kind)
    end)

    it('breakindent + showbreak + linebreak', function()
      command('set breakindent showbreak=>> linebreak')
      api.nvim_buf_set_lines(0, 0, -1, true, { '    ' .. long, '\t' .. long })
      show(screen, [[
        ^    the quick brown fox jumps |
            {1:>>}over the lazy dog and   |
            {1:>>}keeps running far away  |
                the quick brown fox   |
                {1:>>}jumps over the lazy |
                {1:>>}dog and keeps       |
                {1:>>}running far away    |
        {1:~                             }|*2
                                      |
      ]])
      local _, checked = check_oracle(screen)
      eq(2 * #long + 5, checked)
    end)

    local conceal_snaps = {
      [[
        one {14:1} two {14:2} three {14:3} four      |
         {14: } five the quick brown fox   |
        jumps over the lazy dog and ke|
        eps running far away          |
        ^tail line                     |
        {1:~                             }|*4
                                      |
      ]],
      [[
        one {14:1} two {14:2} three {14:3} four      |
          five the quick brown fox    |
        jumps over the lazy dog and ke|
        eps running far away          |
        ^tail line                     |
        {1:~                             }|*4
                                      |
      ]],
      [[
        one  two  three  four         |
          five the quick brown fox    |
        jumps over the lazy dog and ke|
        eps running far away          |
        ^tail line                     |
        {1:~                             }|*4
                                      |
      ]],
    }
    for _, cole in ipairs({ 1, 2, 3 }) do
      it('syntax + matchadd + extmark conceal, conceallevel=' .. cole, function()
        api.nvim_buf_set_lines(0, 0, -1, true, {
          'one SYN two MAT three EXT four EXN five ' .. long,
          'tail line',
        })
        command('syntax match Hid /SYN/ conceal cchar=1')
        command([[call matchadd('Conceal', 'MAT', 10, -1, {'conceal': '2'})]])
        local ns = api.nvim_create_namespace('t')
        api.nvim_buf_set_extmark(0, ns, 0, 22, { end_col = 25, conceal = '3' })
        api.nvim_buf_set_extmark(0, ns, 0, 31, { end_col = 34, conceal = '' })
        command('set conceallevel=' .. cole .. ' concealcursor=nvic')
        command('normal! G')
        show(screen, conceal_snaps[cole])
        local by, checked = check_oracle(screen, nil, function(ch)
          return not ch:match('[SYNMATEXN]')
        end)
        eq(#'one  two  three  four  five ' + #long + #'tail line', checked)
        local first = { ['0:4'] = '1', ['0:12'] = '2', ['0:22'] = '3', ['0:31'] = ' ' }
        for key, cchar in pairs(first) do
          local r = by[key]
          eq('concealed', r.kind, key)
          eq(true, r.visible, key)
          if cole < 3 and not (cole == 2 and cchar == ' ') then
            eq(cchar, at(screen, r), key)
          end
        end
        eq('concealed', by['0:5'].kind)
        eq('concealed', by['0:33'].kind)
      end)
    end

    it('cursor line is drawn unconcealed without concealcursor', function()
      api.nvim_buf_set_lines(0, 0, -1, true, { 'aXXb', 'cXXd' })
      command('syntax match Hid /XX/ conceal cchar=* | set conceallevel=2 concealcursor=')
      show(screen, [[
        ^aXXb                          |
        c{14:*}d                           |
        {1:~                             }|*7
                                      |
      ]])
      local by, checked = check_oracle(screen)
      eq(6, checked)
      eq({ { 0, 2, 2 } }, by['0:2'].segs)
      eq('concealed', by['1:1'].kind)
      eq('concealed', by['1:2'].kind)
      eq({ { 1, 1, 1 } }, by['1:2'].segs)
      eq({ { 1, 2, 2 } }, by['1:3'].segs)
    end)

    it('conceal_lines', function()
      api.nvim_buf_set_lines(0, 0, -1, true, { 'line one', 'hidden', 'line three' })
      local ns = api.nvim_create_namespace('t')
      api.nvim_buf_set_extmark(0, ns, 1, 0, { conceal_lines = '' })
      command('set conceallevel=2')
      show(screen, [[
        ^line one                      |
        line three                    |
        {1:~                             }|*7
                                      |
      ]])
      local by = check_oracle(screen)
      eq('hidden_line', by['1:0'].kind)
      eq(false, by['1:0'].visible)
      eq({ { 1, 0, 0 } }, by['2:0'].segs)
      local map = api.nvim__win_screen_map(0, {})
      eq({ 0, 'text' }, { map.rows[1].lnum, map.rows[1].kind })
      eq({ 2, 'text' }, { map.rows[2].lnum, map.rows[2].kind })
    end)

    it('inline virt_text', function()
      api.nvim_buf_set_lines(0, 0, -1, true, { 'abc def', 'x' })
      local ns = api.nvim_create_namespace('t')
      api.nvim_buf_set_extmark(0, ns, 0, 4, { virt_text = { { 'HINT' } }, virt_text_pos = 'inline' })
      api.nvim_buf_set_extmark(0, ns, 0, 7, { virt_text = { { '<<' } }, virt_text_pos = 'inline' })
      show(screen, [[
        ^abc HINTdef<<                 |
        x                             |
        {1:~                             }|*7
                                      |
      ]])
      local by = check_oracle(screen)
      eq({ { 0, 8, 8 } }, by['0:4'].segs)
      eq(4, by['0:4'].pre)
      eq('d', at(screen, by['0:4']))
      eq(0, by['0:5'].pre)
      local eol = cells({ { 0, 7 } })[1]
      eq('eol', eol.kind)
      eq(2, eol.pre)
      eq({ { 0, 13, 13 } }, eol.segs)
    end)

    it('virt_lines', function()
      api.nvim_buf_set_lines(0, 0, -1, true, { 'first', 'second', 'third' })
      local ns = api.nvim_create_namespace('t')
      api.nvim_buf_set_extmark(0, ns, 1, 0, { virt_lines = { { { 'above' } } }, virt_lines_above = true })
      api.nvim_buf_set_extmark(0, ns, 1, 0, { virt_lines = { { { 'below1' } }, { { 'below2' } } } })
      api.nvim_buf_set_extmark(0, ns, 2, 0, { virt_lines = { { { 'last' } } } })
      show(screen, [[
        ^first                         |
        above                         |
        second                        |
        below1                        |
        below2                        |
        third                         |
        last                          |
        {1:~                             }|*2
                                      |
      ]])
      local by = check_oracle(screen)
      eq({ { 2, 0, 0 } }, by['1:0'].segs)
      eq({ { 5, 0, 0 } }, by['2:0'].segs)
      local kinds = {}
      for _, r in ipairs(api.nvim__win_screen_map(0, {}).rows) do
        table.insert(kinds, r.lnum .. r.kind)
      end
      eq({ '0text', '1virt', '1text', '2virt', '2virt', '2text', '2virt', '-1eob', '-1eob' }, kinds)
    end)

    it('tabs and wide chars', function()
      command('set tabstop=8')
      api.nvim_buf_set_lines(0, 0, -1, true, {
        'a\tb\tc',
        'xxxxxxxxxxxxxxxxxxxxxxxxxx\ty',
        '日本語のテキストは二桁幅の文字で折り返します',
      })
      show(screen, [[
        ^a       b       c             |
        xxxxxxxxxxxxxxxxxxxxxxxxxx    |
          y                           |
        日本語のテキストは二桁幅の文字|
        で折り返します                |
        {1:~                             }|*4
                                      |
      ]])
      local by = check_oracle(screen)
      eq({ { 0, 1, 7 } }, by['0:1'].segs)
      -- a tab across the wrap
      eq({ { 1, 26, 29 }, { 2, 0, 1 } }, by['1:26'].segs)
      eq({ { 3, 0, 1 } }, by['2:0'].segs)
    end)

    it('closed fold', function()
      api.nvim_buf_set_lines(0, 0, -1, true, { 'one', 'two', 'three', 'four' })
      command('1,3fold')
      show(screen, [[
        {13:^+--  3 lines: one·············}|
        four                          |
        {1:~                             }|*7
                                      |
      ]])
      local by = check_oracle(screen)
      for _, key in ipairs({ '0:0', '1:1', '2:2' }) do
        eq('fold', by[key].kind, key)
        eq(0, by[key].segs[1][1], key)
      end
      eq({ { 1, 0, 0 } }, by['3:0'].segs)
      eq('fold', api.nvim__win_screen_map(0, {}).rows[1].kind)
    end)

    it('smoothscroll skipcol', function()
      command('set smoothscroll')
      api.nvim_buf_set_lines(0, 0, -1, true, { long .. ' ' .. long, 'next' })
      feed('<C-E>')
      show(screen, [[
        {1:<<<}e lazy dog and keeps runnin|
        ^g far away the quick brown fox|
         jumps over the lazy dog and k|
        eeps running far away         |
        next                          |
        {1:~                             }|*4
                                      |
      ]])
      local by = check_oracle(screen)
      eq('offscreen', by['0:0'].kind)
      eq(true, by['0:30'].skipcol_overlay)
      eq({ { 0, 3, 3 } }, by['0:33'].segs)
      local map = api.nvim__win_screen_map(0, {})
      eq(30, map.skipcol)
    end)

    it('float with border', function()
      local buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(buf, 0, -1, true, { 'float text that wraps here', 'two' })
      local win = api.nvim_open_win(buf, false, {
        relative = 'editor', row = 2, col = 5, width = 12, height = 4, border = 'single',
      })
      show(screen, [[
        ^                              |
        {1:~                             }|
        {1:~    }┌────────────┐{1:           }|
        {1:~    }│{4:float text t}│{1:           }|
        {1:~    }│{4:hat wraps he}│{1:           }|
        {1:~    }│{4:re          }│{1:           }|
        {1:~    }│{4:two         }│{1:           }|
        {1:~    }└────────────┘{1:           }|
        {1:~                             }|
                                      |
      ]])
      local by = check_oracle(screen, win)
      eq({ 3, 6 }, by['0:0'].abs)
      eq({ 4, 6 }, by['0:12'].abs)
      local map = api.nvim__win_screen_map(win, {})
      eq({ 3, 6, 12, 4 }, { map.inner_row, map.inner_col, map.width, map.height })
    end)

    it('number + signcolumn + statuscolumn', function()
      api.nvim_buf_set_lines(0, 0, -1, true, { long, 'two' })
      command('set number signcolumn=yes')
      show(screen, [[
        {7:  }{8:  1 }^the quick brown fox jump|
        {7:  }{8:    }s over the lazy dog and |
        {7:  }{8:    }keeps running far away  |
        {7:  }{8:  2 }two                     |
        {1:~                             }|*5
                                      |
      ]])
      local by = check_oracle(screen)
      eq({ { 0, 6, 6 } }, by['0:0'].segs)
      command([[set statuscolumn=%l\ %s\ X]])
      show(screen, [[
        {8:1 }{7:  }{8: X}^the quick brown fox jump|
        {8: }{7:  }{8: X }s over the lazy dog and |
        {8: }{7:  }{8: X }keeps running far away  |
        {8:2 }{7:  }{8: X}two                     |
        {1:~                             }|*5
                                      |
      ]])
      by = check_oracle(screen)
      eq('X', cell(screen, 0, by['0:0'].abs[2] - 1))
    end)

    it('wide char padding at the wrap, concealed wide char', function()
      api.nvim_buf_set_lines(0, 0, -1, true, { 'x日本語のテキストは二桁幅の文字です', 'a語b' })
      command('syntax match Hid /語/ conceal cchar=G')
      command('set conceallevel=2')
      show(screen, [[
        ^x日本語のテキストは二桁幅の文{1:>}|
        字です                        |
        a{14:G}b                           |
        {1:~                             }|*6
                                      |
      ]])
      local by = check_oracle(screen, nil, function(ch)
        return ch ~= '語'
      end)
      -- '字' does not fit in the last column, a '>' is drawn there
      eq({ { 1, 0, 1 } }, by['0:43'].segs)
      eq('>', cell(screen, 0, 29))
      eq('concealed', by['1:1'].kind)
      eq('G', at(screen, by['1:1']))
      eq({ { 2, 2, 2 } }, by['1:4'].segs)
    end)

    it('rightleft', function()
      command('set rightleft')
      api.nvim_buf_set_lines(0, 0, -1, true, { long, 'two' })
      show(screen, [[
        revo spmuj xof nworb kciuq eh^t|
        ninnur speek dna god yzal eht |
                            yawa raf g|
                                   owt|
        {1:                             ~}|*5
                                      |
      ]])
      local by, checked = check_oracle(screen)
      eq(#long + 3, checked)
      eq({ { 0, 29, 29 } }, by['0:0'].segs)
      eq({ { 1, 29, 29 } }, by['0:30'].segs)
    end)

    it('diff filler', function()
      api.nvim_buf_set_lines(0, 0, -1, true, { 'a', 'b', 'c' })
      command('diffthis | vnew')
      api.nvim_buf_set_lines(0, 0, -1, true, { 'a', 'c' })
      command('diffthis')
      show(screen, [[
        {7:  }^a                 │{7:  }a      |
        {7:  }{23:------------------}│{7:  }{22:b      }|
        {7:  }c                 │{7:  }c      |
        {1:~                   }│{1:~        }|*5
        {3:[No Name] [+]        }{2:<me] [+] }|
                                      |
      ]])
      local by = check_oracle(screen)
      eq({ { 2, 2, 2 } }, by['1:0'].segs)
      local kinds = {}
      for _, r in ipairs(api.nvim__win_screen_map(0, {}).rows) do
        table.insert(kinds, r.lnum .. r.kind)
      end
      eq({ '0text', '1fill', '1text' }, { kinds[1], kinds[2], kinds[3] })
    end)

    it('float clamped at the screen edge', function()
      local buf = api.nvim_create_buf(false, true)
      api.nvim_buf_set_lines(buf, 0, -1, true, { 'clamped float', 'x' })
      local win = api.nvim_open_win(buf, false, {
        relative = 'editor', row = 1, col = 25, width = 15, height = 2, border = 'single',
      })
      show(screen, [[
        ^                              |
        {1:~            }┌───────────────┐|
        {1:~            }│{4:clamped float  }│|
        {1:~            }│{4:x              }│|
        {1:~            }└───────────────┘|
        {1:~                             }|*4
                                      |
      ]])
      local by, checked = check_oracle(screen, win)
      eq(14, checked)
      eq({ 2, 14 }, by['0:0'].abs)
    end)

    it('stale data is valid=false without redraw', function()
      api.nvim_buf_set_lines(0, 0, -1, true, { 'abc', 'def' })
      show(screen, [[
        ^abc                           |
        def                           |
        {1:~                             }|*7
                                      |
      ]])
      eq(true, cells({ { 0, 0 } })[1].valid)
      local res = n.exec_lua(function()
        vim.api.nvim_buf_set_lines(0, 0, 1, true, { 'xyz' })
        return {
          vim.api.nvim__win_screen_cells(0, { { 0, 0 } }, {})[1],
          vim.api.nvim__win_screen_map(0, {}).valid,
        }
      end)
      eq(false, res[1].valid)
      eq(false, res[2])
      show(screen, [[
        ^xyz                           |
        def                           |
        {1:~                             }|*7
                                      |
      ]])
      eq(true, cells({ { 0, 0 } })[1].valid)
    end)
  end)
end)

describe('API nvim__win_screen_cells with ext_multigrid', function()
  before_each(clear)

  it('reads the window grid, segs are grid coordinates', function()
    local screen = Screen.new(40, 8, { ext_multigrid = true })
    api.nvim_buf_set_lines(0, 0, -1, true, { long, 'aXXXb c' })
    command('syntax match Hid /XX/ conceal cchar=* | set conceallevel=2')
    command('vsplit')
    show(screen, { grid = [[
      ## grid 1
        [4:--------------------]│[2:-------------------]|*6
        {3:[No Name] [+]        }{2:[No Name] [+]      }|
        [3:----------------------------------------]|
      ## grid 2
        the quick brown fox|
         jumps over the laz|
        y dog and keeps run|
        ning far away      |
        a{14:*}Xb c             |
        {1:~                  }|
      ## grid 3
                                                |
      ## grid 4
        ^the quick brown fox |
        jumps over the lazy |
        dog and keeps runnin|
        g far away          |
        a{14:*}Xb c              |
        {1:~                   }|
    ]] })
    local win = api.nvim_get_current_win()
    local pos, chars = all_positions(win)
    local res = cells(pos, win)
    local wpos = api.nvim_win_get_position(win)
    local grid = screen._grids[4]
    local checked = 0
    for i, r in ipairs(res) do
      if r.kind == 'text' then
        local s = r.segs[1]
        eq(chars[i], grid.rows[s[1] + 1][s[2] + 1].text)
        eq({ wpos[1] + s[1], wpos[2] + s[2] }, r.abs)
        checked = checked + 1
      end
    end
    eq(#long + 5, checked)
    eq('*', grid.rows[res[#long + 2].segs[1][1] + 1][res[#long + 2].segs[1][2] + 1].text)
  end)
end)

describe('API nvim__win_screen_map', function()
  before_each(clear)

  it('rows add up to the window height', function()
    local screen = Screen.new(30, 12)
    api.nvim_buf_set_lines(0, 0, -1, true, { long, 'two', long, 'four' })
    command('split | 2,3fold')
    show(screen, [[
      ^the quick brown fox jumps over|
       the lazy dog and keeps runnin|
      g far away                    |
      {13:+--  2 lines: two·············}|
      four                          |
      {3:[No Name] [+]                 }|
      the quick brown fox jumps over|
       the lazy dog and keeps runnin|
      g far away                    |
      two                           |
      {2:[No Name] [+]                 }|
                                    |
    ]])
    for _, win in ipairs(api.nvim_list_wins()) do
      local map = api.nvim__win_screen_map(win, { cells = true })
      eq(api.nvim_win_get_height(win), #map.rows)
      eq(map.height, #map.rows)
      for _, r in ipairs(map.rows) do
        eq(map.width, #r.vcols)
      end
    end
    local map = api.nvim__win_screen_map(0, {})
    local text = 0
    for _, r in ipairs(map.rows) do
      text = text + ((r.kind == 'eob') and 0 or 1)
    end
    eq(api.nvim_win_text_height(0, {}).all, text)
  end)

  it('window in another tab page is not valid', function()
    Screen.new(30, 6)
    api.nvim_buf_set_lines(0, 0, -1, true, { 'abc' })
    local win = api.nvim_get_current_win()
    command('tabnew')
    n.poke_eventloop()
    local map = api.nvim__win_screen_map(win, {})
    eq(false, map.valid)
    for _, r in ipairs(map.rows) do
      eq({ -1, 'eob' }, { r.lnum, r.kind })
    end
    eq({ false, false, 'offscreen' }, (function()
      local r = cells({ { 0, 0 } }, win)[1]
      return { r.valid, r.visible, r.kind }
    end)())
  end)

  it('errors', function()
    eq("Invalid 'positions': expected [row, col] Integer pair",
      t.pcall_err(api.nvim__win_screen_cells, 0, { { 0 } }, {}))
    eq("Invalid 'row': out of range", t.pcall_err(api.nvim__win_screen_cells, 0, { { 5, 0 } }, {}))
  end)
end)
