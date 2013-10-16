require 'uri'

class String
  def strip_heredoc
    indent = scan(/^[ \t]*(?=\S)/).min.size || 0
    gsub(/^[ \t]{#{indent}}/, '')
  end
end

module Alfred

  module Util

    class << self
      # escape text for use in an AppleScript string
      def escape_applescript(str)
        str.to_s.gsub(/(?=["\\])/, '\\')
      end

      def make_webloc(name, url, folder=nil, comment = '')
        date = Time.now.strftime("%m-%d-%Y %I:%M%p")
        folder = Alfred.workflow_folder unless folder
        folder, name, url, comment = [folder, name, url, comment].map do |t|
          escape_applescript(t)
        end

        return %x{
        osascript << __APPLESCRIPT__
        tell application "Finder"
            set webloc to make new internet location file at (POSIX file "#{folder}") ¬
            to "#{url}" with properties ¬
            {name:"#{name}",creation date:(AppleScript's date "#{date}"), ¬
            comment:"#{comment}"}
        end tell
        return POSIX path of (webloc as string)
__APPLESCRIPT__}
      end


      def open_url(url)
        uri = URI.parse(url)
        %x{open #{uri.to_s}}
      end

      def reveal_in_finder(path)
        raise InvalidArgument, "#{path} does not exist." unless File.exist? path
        %x{osascript <<__APPLESCRIPT__
        tell application "Finder"
            try
                reveal POSIX file "#{path}"
                activate
            on error err_msg number err_num
                return err_msg
            end try
        end tell
__APPLESCRIPT__}
      end

    end
  end

end

