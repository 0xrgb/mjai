require "zlib"
require "uri"
require "nokogiri"
require "with_progress"

require "mjai/archive"
require "mjai/pai"
require "mjai/action"
require "mjai/puppet_player"


module Mjai

    class TenhouArchive < Archive
        
        module Util
            
            def on_tenhou_event(elem, next_elem = nil)
              case elem.name
                when "SHUFFLE", "GO", "BYE"
                  # BYE: log out
                  return nil
                when "UN"
                  escaped_names = (0...4).map(){ |i| elem["n%d" % i] }
                  return :broken if escaped_names.index(nil)  # Something is wrong.
                  @names = escaped_names.map(){ |s| URI.decode(s) }
                  return nil
                when "TAIKYOKU"
                  oya = elem["oya"].to_i()
                  log_name = elem["log"] || File.basename(self.path, ".mjlog")
                  uri = "http://tenhou.net/0/?log=%s&tw=%d" % [log_name, (4 - oya) % 4]
                  @first_kyoku_started = false
                  return do_action({:type => :start_game, :uri => uri, :names => @names})
                when "INIT"
                  oya = elem["oya"].to_i()
                  if @first_kyoku_started
                    # Ends the previous kyoku. This is here because there can be multiple AGARIs in
                    # case of daburon, so we cannot detect the end of kyoku in AGARI.
                    do_action({:type => :end_kyoku})
                  end
                  @first_kyoku_started = true
                  do_action({
                    :type => :start_kyoku,
                    :oya => self.players[oya],
                    :dora_marker => pid_to_pai(elem["seed"].split(/,/)[5]),
                  })
                  for i in 0...4
                    player_id = (oya + i) % 4
                    if player_id == 0
                      hai_str = elem["hai"] || elem["hai0"]
                    else
                      hai_str = elem["hai%d" % player_id]
                    end
                    pids = hai_str ? hai_str.split(/,/) : [nil] * 13
                    self.players[player_id].attributes.tenhou_tehai_pids = pids
                    pais = pids.map(){ |s| pid_to_pai(s) }
                    do_action({:type => :haipai, :actor => self.players[player_id], :pais => pais})
                  end
                  return nil
                when /^([T-W])(\d+)?$/i
                  player_id = ["T", "U", "V", "W"].index($1.upcase)
                  pid = $2
                  self.players[player_id].attributes.tenhou_tehai_pids.push(pid)
                  return do_action({
                      :type => :tsumo,
                      :actor => self.players[player_id],
                      :pai => pid_to_pai(pid),
                  })
                when /^([D-G])(\d+)?$/i
                  player_id = ["D", "E", "F", "G"].index($1.upcase)
                  pid = $2
                  self.players[player_id].attributes.tenhou_tehai_pids.delete(pid)
                  return do_action({
                      :type => :dahai,
                      :actor => self.players[player_id],
                      :pai => pid_to_pai(pid),
                  })
                when "REACH"
                  actor = self.players[elem["who"].to_i()]
                  case elem["step"]
                    when "1"
                      return do_action({:type => :reach, :actor => actor})
                    when "2"
                      return do_action({:type => :reach_accepted, :actor => actor})
                    else
                      raise("should not happen")
                  end
                when "AGARI"
                  do_action({
                    :type => :hora,
                    :actor => self.players[elem["who"].to_i()],
                    :target => self.players[elem["fromWho"].to_i()],
                    :pai => pid_to_pai(elem["machi"]),
                  })
                  if elem["owari"]
                    do_action({:type => :end_kyoku})
                    do_action({:type => :end_game})
                  end
                  return nil
                when "RYUUKYOKU"
                  reason_map = {
                    "yao9" => :kyushukyuhai,
                    "kaze4" => :sufonrenta,
                    "reach4" => :suchareach,
                    "ron3" => :sanchaho,
                    "nm" => :nagashimangan,
                    "kan4" => :sukaikan,
                    nil => :fanpai,
                  }
                  reason = reason_map[elem["type"]]
                  raise("unknown reason") if !reason
                  # TODO add actor for some reasons
                  do_action({:type => :ryukyoku, :reason => reason})
                  if elem["owari"]
                    do_action({:type => :end_kyoku})
                    do_action({:type => :end_game})
                  end
                  return nil
                when "N"
                  actor = self.players[elem["who"].to_i()]
                  return do_action(TenhouFuro.new(elem["m"].to_i()).to_action(self, actor))
                when "DORA"
                  do_action({:type => :dora, :dora_marker => pid_to_pai(elem["hai"])})
                  return nil
                when "FURITEN"
                  return nil
                else
                  raise("unknown tag name: %s" % elem.name)
              end
            end
            
            def path
              return nil
            end
            
          module_function
            
            def pid_to_pai(pid)
              return pid ? get_pai(*decompose_pid(pid)) : Pai::UNKNOWN
            end
            
            def decompose_pid(pid)
              pid = pid.to_i()
              return [
                (pid / 4) / 9,
                (pid / 4) % 9 + 1,
                pid % 4,
              ]
            end
            
            def get_pai(type_id, number, cid)
              type = ["m", "p", "s", "t"][type_id]
              # TODO only for games with red 5p
              red = type != "t" && number == 5 && cid == 0
              return Pai.new(type, number, red)
            end
            
        end
        
        # http://p.tenhou.net/img/mentsu136.txt
        class TenhouFuro
            
            include(Util)
            
            def initialize(fid)
              @num = fid
              @target_dir = read_bits(2)
              if read_bits(1) == 1
                parse_chi()
                return
              end
              if read_bits(1) == 1
                parse_pon()
                return
              end
              if read_bits(1) == 1
                parse_kakan()
                return
              end
              if read_bits(1) == 1
                parse_nukidora()
                return
              end
              parse_kan()
            end
            
            attr_reader(:type, :target_dir, :taken, :consumed)
            
            def to_action(game, actor)
              params = {
                :type => @type,
                :actor => actor,
                :pai => @taken,
                :consumed => @consumed,
              }
              if ![:ankan, :kakan].include?(@type)
                params[:target] = game.players[(actor.id + @target_dir) % 4]
              end
              return Action.new(params)
            end
            
            def parse_chi()
              cids = (0...3).map(){ |i| read_bits(2) }
              read_bits(1)
              pattern = read_bits(6)
              seq_kind = pattern / 3
              taken_pos = pattern % 3
              pai_type = seq_kind / 7
              first_number = seq_kind % 7 + 1
              @type = :chi
              @consumed = []
              for i in 0...3
                pai = get_pai(pai_type, first_number + i, cids[i])
                if i == taken_pos
                  @taken = pai
                else
                  @consumed.push(pai)
                end
              end
            end
            
            def parse_pon()
              read_bits(1)
              unused_cid = read_bits(2)
              read_bits(2)
              pattern = read_bits(7)
              pai_kind = pattern / 3
              taken_pos = pattern % 3
              pai_type = pai_kind / 9
              pai_number = pai_kind % 9 + 1
              @type = :pon
              @consumed = []
              j = 0
              for i in 0...4
                next if i == unused_cid
                pai = get_pai(pai_type, pai_number, i)
                if j == taken_pos
                  @taken = pai
                else
                  @consumed.push(pai)
                end
                j += 1
              end
            end
            
            def parse_kan()
              read_bits(2)
              pid = read_bits(8)
              (pai_type, pai_number, key_cid) = decompose_pid(pid)
              @type = @target_dir == 0 ? :ankan : :daiminkan
              @consumed = []
              for i in 0...4
                pai = get_pai(pai_type, pai_number, i)
                if i == key_cid && @type != :ankan
                  @taken = pai
                else
                  @consumed.push(pai)
                end
              end
            end
            
            def parse_kakan()
              taken_cid = read_bits(2)
              read_bits(2)
              pattern = read_bits(7)
              pai_kind = pattern / 3
              taken_pos = pattern % 3
              pai_type = pai_kind / 9
              pai_number = pai_kind % 9 + 1
              @type = :kakan
              @target_dir = 0
              @consumed = []
              for i in 0...4
                pai = get_pai(pai_type, pai_number, i)
                if i == taken_cid
                  @taken = pai
                else
                  @consumed.push(pai)
                end
              end
            end
            
            def read_bits(num_bits)
              mask = (1 << num_bits) - 1
              result = @num & mask
              @num >>= num_bits
              return result
            end
            
        end
        
        include(Util)
        
        def initialize(path)
          super()
          @path = path
          Zlib::GzipReader.open(path) do |f|
            @xml = f.read().force_encoding("utf-8")
          end
        end
        
        attr_reader(:path)
        attr_reader(:xml)
        
        def play()
          @doc = Nokogiri.XML(@xml)
          elems = @doc.root.children
          elems.each_with_index() do |elem, j|
            #puts(elem)  # kari
            if on_tenhou_event(elem, elems[j + 1]) == :broken
              break  # Something is wrong.
            end
          end
        end
        
    end

end