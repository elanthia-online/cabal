require 'ostruct'

class Puritan
  ##
  ## minimal options parser
  ##
  module Opts
    FLAG_PREFIX    = "--"

    def self.parse_command(h, c)
      h[c.to_sym] = true
    end

    def self.parse_flag(h, f)
      (name, val) = f[2..-1].split("=")
      if val.nil?
        h[name.to_sym] = true
      else
        val = val.split(",")

        h[name.to_sym] = val.size == 1 ? val.first : val
      end
    end

    def self.parse(args)
      OpenStruct.new(**args.to_a.reduce(Hash.new) do |opts, v|
        if v.start_with?(FLAG_PREFIX)
          Opts.parse_flag(opts, v)
        else
          Opts.parse_command(opts, v)
        end
        opts
      end)
    end
  end
end
