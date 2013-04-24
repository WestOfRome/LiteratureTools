#!/usr/bin/perl 

# 
# Devin Scannell, 2013 
# 
# GNU GPL v3
# 

unless ( @ARGV ) {
    print <<USAGE;

    Use Pubmed Central OAI API to associate reference PMIDs to query PMCID.
    Secondarily uses pmid2doi API to obtain DOIs for references.

    $0 pmcid [--no_pmid2doi]
    
    Contact Devin Scannell.

USAGE
    exit;
}

########################################
# load module and define API URLs
########################################

use Getopt::Long;
use LWP::Simple;
use XML::Parser;
use Spreadsheet::WriteExcel;

GetOptions(
    'no_pmid2doi' => \$no_pmid2doi
    );

$, = "\t";
$\ = "\n";

my $pmid2doi="http://www.pmid2doi.org/rest/json/doi/";
my $pmcoai = "http://www.pubmedcentral.nih.gov/oai/oai.cgi?verb=GetRecord&metadataPrefix=pmc&identifier=oai:pubmedcentral.nih.gov:";

########################################
# read in commandline PMCID and call PMC API
########################################

my $pmcid = shift @ARGV;
$pmcid =~ s/^[a-zA-Z]+//;
my $xml = get( $pmcoai.$pmcid );

#my $p1 = new XML::Parser(Style => 'Debug');
#$p1->parse($xml);

my ($top,$reflist) = split/\<ref\-list\>/, $xml;

########################################
# process XML header to get article DOI and PMID 
########################################

my @ids = grep {/article\-id\spub\-id\-type/} split/\n/, $top;
my ($doi) =map {s/\<[^\>]+\>//g;$_} grep {/doi/} @ids;
my ($pmid) =map {s/\<[^\>]+\>//g;$_} grep {/pmid/} @ids;

########################################
# process XML to get PMID for each reference. 
# look up reference DOIs using pmid2doi API service.  
# write table that maps query article DOI to reference DOI.
########################################

foreach my $ref ( split/ref\sid/, $reflist ) {
    next unless ++$x >1;
    my @articles = map {s/\<[^\>]+\>//g;$_} grep {/article\-title/} split/\n/, $ref;
    my @pub = map {s/\<[^\>]+\>//g;$_} grep {/pub\-id/} split/\n/, $ref;
    #die($#articles,$#pub) unless $#articles == $#pub;
    my $refdoi = &pmid2doi( $pub[0] ) unless $no_pmid2doi;
    print $pmcid, $pmid, $doi, ++$c, ($pub[0] || "NA"), $refdoi, substr(($articles[0] || "NA"), 0, 50);
}

exit;

########################################
# query pmid 2 doi API and parse. 
# need to add some error checking and QC ... 
########################################

sub pmid2doi {
    my $json = get( $pmid2doi.$_[0] );
    $json =~ /\"doi\"\:\"([^\"]+)\"/;
    return $1 || undef;
}
